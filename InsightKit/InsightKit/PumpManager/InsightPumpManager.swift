import CoreBluetooth
import Foundation
import HealthKit
import LoopKit
import UIKit

public protocol InsightStateObserver: AnyObject {
    func stateDidUpdate(_ state: InsightPumpManagerState, _ oldState: InsightPumpManagerState)
    func connectionDidUpdate(_ connection: BridgeSessionState)
}

public extension InsightStateObserver {
    func connectionDidUpdate(_: BridgeSessionState) {}
}

public enum InsightPumpManagerError: Error, Equatable {
    case deliveryUncertain
    case bolusInProgress
    case notOnboarded
    case scheduleNotConfirmed
    case scheduleMismatch(pump: Double, local: Double)
    case pumpSuspended
    case noBasalSchedule
    case bridgeProblem(String)
    case pumpDataStale

    public var errorDescriptionText: String {
        switch self {
        case .deliveryUncertain:
            return LocalizedString(
                "An earlier insulin command has an unknown result. Resolve it in the pump settings before dosing again.",
                comment: "Insight error"
            )
        case .bolusInProgress:
            return LocalizedString("A bolus is already in progress.", comment: "Insight error")
        case .notOnboarded:
            return LocalizedString("The pump has not been set up.", comment: "Insight error")
        case .scheduleNotConfirmed:
            return LocalizedString(
                "The basal schedule on the pump is not confirmed. Sync the basal profile in the pump settings.",
                comment: "Insight error"
            )
        case let .scheduleMismatch(pump, local):
            return String(
                format: LocalizedString(
                    "The pump runs %.2f U/h but Trio expects %.2f U/h. Sync the basal profile in the pump settings.",
                    comment: "Insight error"
                ),
                pump,
                local
            )
        case .pumpSuspended:
            return LocalizedString("The pump is suspended.", comment: "Insight error")
        case .noBasalSchedule:
            return LocalizedString("No basal schedule is known for the pump.", comment: "Insight error")
        case let .bridgeProblem(text):
            return text
        case .pumpDataStale:
            return LocalizedString(
                "The pump data is more than 15 minutes old. Insulin is not delivered until the pump has been read again.",
                comment: "Insight error"
            )
        }
    }
}

extension InsightPumpManagerError: LocalizedError {
    public var errorDescription: String? { errorDescriptionText }
}

/// LoopKit pump manager for the Accu-Chek Insight, controlled through the InsightBridge Android app.
///
/// Threading: all mutable work happens on `queue`; `state` can be read from any thread.
public final class InsightPumpManager: DeviceManager, @unchecked Sendable {
    public static let pluginIdentifier = "Insight"
    public let pluginIdentifier: String = InsightPumpManager.pluginIdentifier
    public let managerIdentifier: String = InsightPumpManager.pluginIdentifier

    // MARK: collaborators

    let queue: DispatchQueue
    let client: InsightBridgeClient
    let scheduler: BridgeScheduler
    let clock: () -> Date
    let credentialStore: BridgeCredentialStoring
    let log = InsightLog(category: "PumpManager")

    // MARK: state

    private let stateStore: Locked<InsightPumpManagerState>
    private let lastNotifiedStatus: Locked<PumpManagerStatus?> = Locked(nil)
    private let lastNotifiedState: Locked<InsightPumpManagerState>

    public var state: InsightPumpManagerState { stateStore.value }
    public var rawState: PumpManager.RawStateValue { state.rawValue }

    /// Transient (not persisted) states shown while a command is in flight.
    let transient = Locked(Transient())
    struct Transient {
        var bolus: PumpManagerStatus.BolusState?
        var basal: PumpManagerStatus.BasalDeliveryState?
    }

    let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    let stateObservers = WeakSynchronizedSet<InsightStateObserver>()

    let commandQueue: CommandQueue
    private let doseReporterStore = Locked<InsightDoseProgressReporter?>(nil)
    /// Written on the manager queue, read from LoopKit threads (`createBolusProgressReporter`): lock-protected.
    var doseReporter: InsightDoseProgressReporter? {
        get { doseReporterStore.value }
        set { doseReporterStore.value = newValue }
    }

    var provideHeartbeat = false
    var lastHeartbeat = Date.distantPast
    var bolusWatch: BridgeCancellable?
    var disconnectTimer: BridgeCancellable?
    var tbrExpiryTimer: BridgeCancellable?
    var uncertaintyRetry: BridgeCancellable?
    var historySyncInFlight = false
    /// Consecutive `inProgress` answers to `getRequestOutcome` (drives the back-off).
    var outcomeAttempts = 0
    /// Last status as received (queue confined).
    var lastStatus: BridgeStatus?
    var lastHistoryEvents: [HistoryEvent] = []
    var historyWasComplete = false
    var matchedPendingBolus = false
    var lastStatusReceived: Date?
    private var timeZoneObserver: NSObjectProtocol?

    // MARK: init

    public init(
        state: InsightPumpManagerState,
        client: InsightBridgeClient? = nil,
        credentialStore: BridgeCredentialStoring = KeychainCredentialStore(),
        queue: DispatchQueue = DispatchQueue(label: "org.nightscout.InsightKit.manager", qos: .userInitiated),
        scheduler: BridgeScheduler? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.clock = clock
        self.credentialStore = credentialStore
        self.scheduler = scheduler ?? DispatchBridgeScheduler(queue: queue)
        stateStore = Locked(state)
        lastNotifiedState = Locked(state)
        commandQueue = CommandQueue(queue: queue)

        if let client {
            self.client = client
        } else {
            let link = BLEBridgeLink(queue: queue)
            let session = BridgeSession(
                link: link, store: credentialStore, scheduler: self.scheduler, queue: queue, appName: Self.appName
            )
            self.client = SessionBridgeClient(session: session, scanner: link)
        }
        self.client.delegate = self
        commonInit()
    }

    public convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = InsightPumpManagerState(rawValue: rawState) else { return nil }
        self.init(state: state)
    }

    static var appName: String {
        let info = Bundle.main.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Trio"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        return "\(name) \(version)"
    }

    private func commonInit() {
        queue.async {
            // A command that was in flight when the app died is uncertain; the state init already flags it.
            if self.state.isDeliveryUncertain { self.log.warning("starting with an uncertain command pending") }
            self.cleanupBolusAfterRestart()
            if let bridgeId = self.state.bridgeId, self.state.isOnboarded {
                self.client.start(bridgeId: bridgeId, peripheral: self.state.peripheralIdentifier.flatMap(UUID.init(uuidString:)))
            }
            self.scheduleTempBasalExpiryNotification()
        }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleTimeZoneChange() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    deinit {
        if let timeZoneObserver { NotificationCenter.default.removeObserver(timeZoneObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillEnterForeground() {
        client.ensureStarted()
    }

    /// An in-progress bolus that survived an app restart is finalized from the history on the next sync.
    private func cleanupBolusAfterRestart() {
        guard let bolus = state.bolus else { return }
        if bolus.phase == .inProgress, bolus.expectedEnd > clock() {
            doseReporter = InsightDoseProgressReporter(total: bolus.units, delivered: bolus.deliveredUnits)
            armBolusWatch()
        }
    }

    // MARK: state access

    @discardableResult func mutate(_ change: (inout InsightPumpManagerState) -> Void) -> InsightPumpManagerState {
        stateStore.mutate(change)
    }

    public var connection: BridgeSessionState { client.sessionState }

    public var bridgeHello: HelloResult? { client.hello }

    /// The bridge answered a session start with "unknown client" once; it is only believed when it repeats.
    public var repairSuspected: Bool { client.repairSuspected }

    // MARK: DeviceManager

    public var localizedTitle: String {
        LocalizedString("Accu-Chek Insight", comment: "Pump manager title")
    }

    public var isOnboarded: Bool { state.isOnboarded }

    public var inSignalLoss: Bool {
        let s = state
        if case .ready = connection, !s.isStatusStale() { return false }
        guard let last = s.lastBridgeContact else { return s.isOnboarded }
        return clock().timeIntervalSince(last) > 12 * 60
    }

    public var isInoperable: Bool { false }

    public var debugDescription: String {
        ["## InsightPumpManager", state.debugDescription, "connection: \(connection)"].joined(separator: "\n")
    }

    // MARK: status

    func makeDevice() -> HKDevice {
        let s = state
        return HKDevice(
            name: managerIdentifier,
            manufacturer: "Roche",
            model: s.isSimulated ? "Accu-Chek Insight (simulated)" : "Accu-Chek Insight",
            hardwareVersion: nil,
            firmwareVersion: s.pumpFirmware,
            softwareVersion: s.bridgeVersion,
            localIdentifier: s.pumpSerial,
            udiDeviceIdentifier: nil
        )
    }

    func computeStatus() -> PumpManagerStatus {
        let s = state
        let now = clock()
        return PumpManagerStatus(
            timeZone: s.pumpTimeZone,
            device: makeDevice(),
            pumpBatteryChargeRemaining: s.batteryPercent.map { $0 / 100 },
            basalDeliveryState: basalDeliveryState(s, now: now),
            bolusState: bolusState(s),
            insulinType: s.insulinType,
            deliveryIsUncertain: s.isDeliveryUncertain
        )
    }

    private func basalDeliveryState(_ s: InsightPumpManagerState, now: Date) -> PumpManagerStatus.BasalDeliveryState {
        if let t = transient.value.basal { return t }
        if s.isSuspended { return .suspended(s.suspendedSince ?? s.lastStatusDate ?? now) }
        if let tbr = s.runningTempBasal(at: now) {
            return .tempBasal(DoseFactory.tempBasalDose(tbr, mutable: true, insulinType: s.insulinType))
        }
        return .active(s.lastStatusDate ?? now)
    }

    private func bolusState(_ s: InsightPumpManagerState) -> PumpManagerStatus.BolusState {
        if let t = transient.value.bolus { return t }
        if let bolus = s.bolus {
            // A bolus that was guessed to be finished, but is still inside its planned delivery time, may still be
            // running: it stays "in progress" so that it can be cancelled.
            let maybeRunning = bolus.phase == .finished && !bolus.stopped && bolus.bolusId != nil && bolus.plannedEnd > clock()
            if bolus.phase == .inProgress || maybeRunning {
                return .inProgress(DoseFactory.bolusDose(bolus, mutable: true, insulinType: s.insulinType))
            }
        }
        return .noBolus
    }

    // MARK: notifications

    /// Tells observers + LoopKit that the state changed (persist + status). Safe from any queue.
    func notifyStateDidChange() {
        let newState = state
        let newStatus = computeStatus()
        var previousState = newState
        lastNotifiedState.mutate { old in
            previousState = old
            old = newState
        }

        var oldStatus = newStatus
        lastNotifiedStatus.mutate { old in
            if let o = old { oldStatus = o }
            old = newStatus
        }

        stateObservers.forEach { $0.stateDidUpdate(newState, previousState) }
        pumpDelegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.pumpManagerDidUpdateState(self)
            delegate?.pumpManager(self, didUpdate: newStatus, oldStatus: oldStatus)
        }
        statusObservers.forEach { $0.pumpManager(self, didUpdate: newStatus, oldStatus: oldStatus) }
    }

    /// Persists the state *before* returning (used right before a dosing command is sent, so that a crash
    /// during the command leaves a record that its outcome is uncertain).
    func persistNow() {
        // Never `sync` onto the delegate queue: if that queue is waiting for us this would deadlock. Wait with a
        // bound instead; the state is also persisted by the regular update right after.
        let done = DispatchSemaphore(value: 0)
        pumpDelegate.queue.async { [weak self] in
            if let self, let delegate = self.pumpDelegate.delegate { delegate.pumpManagerDidUpdateState(self) }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut { log.warning("persisting before sending timed out") }
    }

    func reportReservoir(units: Double, at date: Date) {
        pumpDelegate.notify { [weak self] delegate in
            guard let self, let delegate else { return }
            delegate.pumpManager(self, didReadReservoirValue: units, at: date) { _ in }
        }
    }

    func emitHeartbeatIfRequested() {
        guard provideHeartbeat, clock().timeIntervalSince(lastHeartbeat) > 2 * 60 else { return }
        lastHeartbeat = clock()
        pumpDelegate.notify { [weak self] delegate in
            guard let self else { return }
            delegate?.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    // MARK: delivery duration

    /// Insight delivers roughly 1 U per 40 s (estimate; real progress comes from bridge events).
    public static func deliveryDuration(units: Double) -> TimeInterval {
        max(units * 40, 5)
    }
}

// MARK: - Serial command queue

/// Runs async units of work one at a time on `queue`.
final class CommandQueue {
    private let queue: DispatchQueue
    private var items: [(name: String, isSafety: Bool, work: (@escaping () -> Void) -> Void)] = []
    private var running = false

    init(queue: DispatchQueue) { self.queue = queue }

    /// `work` must call `done` exactly once. Safe to call from any queue.
    /// Safety commands (suspend, cancel TBR, cancel bolus) go to the front of the waiting line.
    func enqueue(_ name: String, safety: Bool = false, _ work: @escaping (@escaping () -> Void) -> Void) {
        queue.async {
            if safety {
                let index = self.items.firstIndex { !$0.isSafety } ?? self.items.count
                self.items.insert((name, true, work), at: index)
            } else {
                self.items.append((name, false, work))
            }
            self.pump()
        }
    }

    var isIdle: Bool { !running && items.isEmpty }

    /// A safety command is waiting: long reads should stop between pages (call on the manager queue).
    var hasSafetyWaiting: Bool { items.contains { $0.isSafety } }

    private func pump() {
        guard !running, !items.isEmpty else { return }
        running = true
        let item = items.removeFirst()
        var finished = false
        item.work { [weak self] in
            self?.queue.async {
                guard !finished else { return } // done() twice is a bug, never run the next item twice
                finished = true
                self?.running = false
                self?.pump()
            }
        }
    }
}

// MARK: - Dose progress reporter

final class InsightDoseProgressReporter: DoseProgressReporter {
    private let lock = UnfairLock()
    private var observers = WeakSet<DoseProgressObserver>()
    private let total: Double
    private var delivered: Double

    init(total: Double, delivered: Double = 0) {
        self.total = max(total, 0.0001)
        self.delivered = delivered
    }

    var progress: DoseProgress {
        let value = lock.withLock { delivered }
        return DoseProgress(deliveredUnits: value, percentComplete: min(value / total, 1))
    }

    func addObserver(_ observer: DoseProgressObserver) { lock.withLock { observers.insert(observer)
        return } }
    func removeObserver(_ observer: DoseProgressObserver) { lock.withLock { observers.remove(observer)
        return } }

    func notify(deliveredUnits: Double) {
        let copy = lock.withLock { () -> WeakSet<DoseProgressObserver> in
            delivered = min(max(deliveredUnits, delivered), total)
            return observers
        }
        for observer in copy { observer.doseProgressReporterDidUpdate(self) }
    }

    func complete() { notify(deliveredUnits: total) }
}
