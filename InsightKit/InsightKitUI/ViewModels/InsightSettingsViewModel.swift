import Combine
import Foundation
import LoopKit
import LoopKitUI

final class InsightSettingsViewModel: ObservableObject, InsightStateObserver {
    enum Action: Equatable {
        case suspend
        case resume
        case syncTime
        case syncBasal
        case refresh
        case stopTempBasal
    }

    @Published private(set) var state: InsightPumpManagerState
    @Published private(set) var connection: BridgeSessionState
    @Published private(set) var now = Date()
    /// Running actions with their token. Safety actions (suspend, stop temp basal) run next to anything else.
    @Published private(set) var running = [Action: Int]()
    /// The running non-safety action (nil: none). Settable for previews/tests.
    var busyAction: Action? {
        get { running.first { !Self.isSafety($0.key) }?.key }
        set {
            for key in running.keys where !Self.isSafety(key) { running[key] = nil }
            if let newValue { actionToken += 1
                running[newValue] = actionToken }
        }
    }

    func isBusy(_ action: Action) -> Bool { running[action] != nil }
    static func isSafety(_ action: Action) -> Bool { action == .suspend || action == .stopTempBasal }
    @Published var resultMessage: ResultMessage?
    private var actionToken = 0

    struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    let manager: InsightPumpManager
    let supportedInsulinTypes: [InsulinType]
    /// Navigation hooks owned by the coordinator. A missing hook is reported, never silently ignored.
    var onRepair: (() -> Void)?
    var onResolveUncertainty: (() -> Void)?
    var onDelete: (() -> Void)?

    /// How long an action may stay "busy" without an answer before the screen says so (and unblocks).
    static var actionWatchdog: TimeInterval = 75

    private var timer: AnyCancellable?

    init(manager: InsightPumpManager, supportedInsulinTypes: [InsulinType]) {
        self.manager = manager
        self.supportedInsulinTypes = supportedInsulinTypes
        state = manager.state
        connection = manager.connection
        manager.addStateObserver(self, queue: .main)
        timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect().sink { [weak self] date in
            self?.now = date
        }
    }

    deinit {
        manager.removeStateObserver(self)
    }

    func stateDidUpdate(_ state: InsightPumpManagerState, _: InsightPumpManagerState) {
        self.state = state
        connection = manager.connection
        now = Date()
    }

    func connectionDidUpdate(_ connection: BridgeSessionState) {
        self.connection = connection
    }

    // MARK: derived values

    var isSimulated: Bool { state.isSimulated }

    var capacity: Double {
        // 160 U prefilled cartridge, 315 U cartridge filled by the user
        InsightPumpSpec.reservoirCapacity
    }

    var deliveryTitle: String {
        if state.isDeliveryUncertain { return L("Delivery uncertain") }
        if state.isSuspended { return L("Insulin suspended") }
        if let tbr = state.runningTempBasal(at: now) { return L("Temp basal %d%%", tbr.percent) }
        return L("Insulin delivery active")
    }

    var deliverySubtitle: String? {
        if state.isSuspended, let since = state.suspendedSince {
            return L("since %@", InsightFormat.time.string(from: since))
        }
        if let tbr = state.runningTempBasal(at: now) {
            let remaining = max((tbr.plannedEnd.timeIntervalSince(now) / 60).clampedInt, 0)
            return L("%d min remaining", remaining)
        }
        return nil
    }

    var deliveryIsProblem: Bool { state.isSuspended || state.isDeliveryUncertain }

    var scheduledBasalNow: Double? {
        state.basalSchedule?.rate(at: now, in: state.pumpTimeZone) ?? state.bridgeBasalRate
    }

    var effectiveBasalNow: Double? {
        guard let scheduled = scheduledBasalNow else { return nil }
        if state.isSuspended { return 0 }
        if let tbr = state
            .runningTempBasal(at: now) { return TempBasalConverter.effectiveRate(percent: tbr.percent, scheduledRate: scheduled) }
        return scheduled
    }

    var bolusDescription: String? {
        guard let bolus = state.bolus, bolus.phase == .inProgress else { return nil }
        return L("%@ of %@", InsightFormat.units(bolus.deliveredUnits, digits: 2), InsightFormat.units(bolus.units, digits: 2))
    }

    var linkStatus: InsightLinkStatus {
        _ = now // re-evaluated with the periodic tick ("bridge not found" appears after a while)
        return manager.linkStatus
    }

    var connectionTitle: String {
        switch linkStatus {
        case .connected: return L("Connected")
        case let .reconnecting(since): return L("Reconnecting since %@", InsightFormat.time.string(from: since))
        case let .bridgeNotFound(since): return L("Bridge not found since %@", InsightFormat.time.string(from: since))
        case let .bluetoothUnavailable(reason): return reason
        case .needsRepair: return L("Pair the bridge again")
        case .incompatible: return L("Incompatible app version")
        case .pairing: return L("Pairing…")
        case .idle: return L("Not connected")
        }
    }

    /// Extra line under the bridge status that says what to do.
    var connectionHint: String? {
        switch linkStatus {
        case .bridgeNotFound:
            return L(
                "Trio keeps searching in the background. Check that the Android phone is on, the InsightBridge app is running and Bluetooth is enabled on both phones."
            )
        case .reconnecting:
            return L("Trio keeps trying to reconnect by itself. You do not need to do anything.")
        default: return nil
        }
    }

    var loopBlockedReason: String? { state.loopBlockedReason }

    var profileWasSimplified: Bool { state.simplifiedProfileSource != nil }

    var connectionIsOK: Bool { connection == .ready }
    var bridgeStatusIsProblem: Bool {
        switch linkStatus {
        case .connected: return false
        case .idle,
             .pairing,
             .reconnecting: return false
        default: return true
        }
    }

    var repairSuspected: Bool { manager.repairSuspected && connection != .ready }

    var pumpLinkTitle: String {
        switch state.pumpLink {
        case .connected: return L("Pump connected")
        case .connecting: return L("Bridge is connecting to the pump…")
        case .disconnected: return L("Bridge cannot reach the pump")
        case .notPaired: return L("Bridge has no pump paired")
        case .unknown: return L("Unknown")
        }
    }

    var pumpLinkIsOK: Bool { state.pumpLink == .connected }

    var lastCommunication: String { InsightFormat.relativeTime(state.lastBridgeContact, now: now) }

    var lastPumpRead: String { InsightFormat.relativeTime(state.lastPumpReadDate, now: now) }

    var activeAlert: (info: InsightAlertInfo, alert: BridgeAlert)? {
        guard let alert = state.activePumpAlert, !alert.isSnoozed else { return nil }
        return (InsightAlertCatalog.info(for: alert), alert)
    }

    var pendingDescription: String? {
        guard let pending = state.pendingCommand, pending.isUncertain else { return nil }
        switch pending.kind {
        case .bolus: return L("Bolus of %@", InsightFormat.units(pending.units, digits: 2))
        case .setTBR: return L("Temp basal %d%%", pending.percent ?? 0)
        case .cancelTBR: return L("Cancel temp basal")
        case .suspend: return L("Suspend insulin")
        case .resume: return L("Resume insulin")
        }
    }

    var timeOffsetText: String? {
        guard manager.needsTimeSync else { return nil }
        if let drift = state.pumpTimeDriftSeconds, abs(drift) > 60 {
            return L("Pump clock is off by %d min", (abs(drift) / 60).clampedInt)
        }
        return L("Pump time zone differs from this iPhone")
    }

    var scheduleStatus: String {
        if state.basalSchedule == nil { return L("Unknown") }
        return state.basalScheduleSynced ? L("Confirmed on pump") : L("Not confirmed")
    }

    // MARK: header values (same wording/structure as the other pump kits' settings)

    var isSuspended: Bool { state.isSuspended }
    var runningTempBasal: ActiveTempBasal? { state.runningTempBasal(at: now) }
    var isTempBasal: Bool { runningTempBasal != nil }

    var basalSectionTitle: String {
        if isSuspended { return L("Insulin Delivery") }
        if isTempBasal { return L("Temp Basal") }
        return L("Scheduled Basal")
    }

    var tempBasalRemaining: String? {
        guard let tbr = runningTempBasal else { return nil }
        let minutes = max((tbr.plannedEnd.timeIntervalSince(now) / 60).clampedInt, 0)
        return L("%d%% • %d min remaining", tbr.percent, minutes)
    }

    var basalRateValue: Double? { isSuspended ? nil : effectiveBasalNow }

    var reservoirLevelWarning: Double { 20 }

    /// The pump's clock, derived from the drift reported by the bridge.
    var pumpTimeText: String {
        guard let drift = state.pumpTimeDriftSeconds, drift.isFinite else { return "–" }
        return InsightFormat.time.string(from: now.addingTimeInterval(drift))
    }

    var showPumpTimeSyncWarning: Bool { manager.needsTimeSync }

    var checkedAtText: String { InsightFormat.relativeTime(state.lastPumpReadDate, now: now) }

    // MARK: actions

    /// Why `action` cannot start right now (nil: it can). Risk-reducing actions (suspend, stop temp basal) are never
    /// blocked by an uncertain command; actions that add insulin or rewrite the profile are.
    func blockedReason(for action: Action) -> String? {
        if Self.isSafety(action) {
            // Never queued behind other actions or blocked by an uncertain command; only a repeat of itself waits.
            return isBusy(action) ? L("This action is already running.") : nil
        }
        if busyAction != nil { return L("Another action is still running. Please wait a moment.") }
        switch action {
        case .refresh,
             .stopTempBasal,
             .suspend,
             .syncTime:
            return nil
        case .resume,
             .syncBasal:
            if state.isDeliveryUncertain {
                return L("An earlier insulin command has an unknown result. Resolve the uncertain delivery first.")
            }
            return nil
        }
    }

    /// Starts `action` if possible and returns its token. Otherwise the reason is shown: a tap never does nothing.
    private func begin(_ action: Action, title: String) -> Int? {
        if let reason = blockedReason(for: action) {
            resultMessage = ResultMessage(title: title, text: reason)
            return nil
        }
        actionToken += 1
        let token = actionToken
        running[action] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionWatchdog) { [weak self] in
            self?.watchdogFired(action, token: token, title: title)
        }
        return token
    }

    func showBlocked(title: String, reason: String) {
        resultMessage = ResultMessage(title: title, text: reason)
    }

    private func watchdogFired(_ action: Action, token: Int, title: String) {
        guard running[action] == token else { return }
        running[action] = nil
        resultMessage = ResultMessage(
            title: title,
            text: L(
                "There is no answer yet. The connection to the bridge may be down; Trio keeps trying. Check the pump status before repeating the action."
            )
        )
    }

    /// Ends the action run `token` belongs to. A late answer after the watchdog (or after a newer run of the same
    /// action started) never clears the newer run's busy flag.
    private func end(_ action: Action, token: Int) {
        if running[action] == token { running[action] = nil }
    }

    func stopTempBasal() {
        let title = L("Stop Temp Basal")
        guard let token = begin(.stopTempBasal, title: title) else { return }
        manager.stopTempBasal { error in
            self.end(.stopTempBasal, token: token)
            if let error {
                self.resultMessage = ResultMessage(title: title, text: error.localizedDescription)
            } else {
                self.resultMessage = ResultMessage(title: title, text: L("The temp basal was stopped."))
            }
        }
    }

    func suspend() {
        run(.suspend, title: L("Suspend insulin"), success: L("Insulin delivery is suspended.")) { done in
            self.manager.suspend(completion: done)
        }
    }

    func resume() {
        run(.resume, title: L("Resume insulin"), success: L("Insulin delivery is resumed.")) { done in
            self.manager.resume(completion: done)
        }
    }

    func syncTime() {
        let title = L("Pump time")
        guard let token = begin(.syncTime, title: title) else { return }
        manager.syncTime { result in
            DispatchQueue.main.async {
                self.end(.syncTime, token: token)
                switch result {
                case .success:
                    self.resultMessage = ResultMessage(title: title, text: L("The pump time was set."))
                case let .failure(error):
                    self.resultMessage = ResultMessage(title: L("Could not set the time"), text: error.localizedDescription)
                }
            }
        }
    }

    func syncBasalProfile() {
        guard let token = begin(.syncBasal, title: L("Basal profile")) else { return }
        manager.resyncBasalProfile { result in
            self.end(.syncBasal, token: token)
            switch result {
            case .success:
                self.resultMessage = ResultMessage(
                    title: L("Basal profile"),
                    text: L("The basal profile was written to the pump and verified.")
                )
            case let .failure(error):
                self.resultMessage = ResultMessage(title: L("Could not sync the basal profile"), text: error.localizedDescription)
            }
        }
    }

    func refresh() {
        let title = L("Sync pump data")
        guard let token = begin(.refresh, title: title) else { return }
        manager.refreshNow { result in
            self.end(.refresh, token: token)
            if case let .failure(error) = result {
                self.resultMessage = ResultMessage(title: title, text: error.localizedDescription)
            }
        }
    }

    func requestRepair() {
        guard let onRepair else {
            resultMessage = ResultMessage(title: L("Pair bridge again"), text: L("This is not available on this screen."))
            return
        }
        onRepair()
    }

    func requestResolveUncertainty() {
        guard let onResolveUncertainty else {
            resultMessage = ResultMessage(
                title: L("Resolve uncertain delivery"), text: L("This is not available on this screen.")
            )
            return
        }
        onResolveUncertainty()
    }

    func requestDelete() {
        guard let onDelete else {
            resultMessage = ResultMessage(title: L("Delete Pump"), text: L("This is not available on this screen."))
            return
        }
        onDelete()
    }

    private func run(_ action: Action, title: String, success: String, _ work: (@escaping (Error?) -> Void) -> Void) {
        guard let token = begin(action, title: title) else { return }
        work { error in
            self.end(action, token: token)
            if let error {
                self.resultMessage = ResultMessage(title: title, text: error.localizedDescription)
            } else {
                self.resultMessage = ResultMessage(title: title, text: success)
            }
        }
    }
}
