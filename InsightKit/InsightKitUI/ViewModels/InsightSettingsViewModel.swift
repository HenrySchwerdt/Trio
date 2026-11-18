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
    @Published var busyAction: Action?
    @Published var resultMessage: ResultMessage?

    struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    let manager: InsightPumpManager
    let supportedInsulinTypes: [InsulinType]
    var onRepair: () -> Void = {}
    var onResolveUncertainty: () -> Void = {}
    var onDelete: () -> Void = {}

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

    var connectionTitle: String {
        switch connection {
        case .ready: return L("Connected")
        case .handshaking: return L("Securing connection…")
        case .linkConnecting: return L("Connecting…")
        case .idle: return L("Not connected")
        case let .bluetoothUnavailable(reason): return reason
        case .needsRepair: return L("Pair the bridge again")
        case .incompatible: return L("Incompatible app version")
        case .pairing: return L("Pairing…")
        }
    }

    var connectionIsOK: Bool { connection == .ready }

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

    func stopTempBasal() {
        busyAction = .stopTempBasal
        manager.stopTempBasal { error in
            self.busyAction = nil
            if let error {
                self.resultMessage = ResultMessage(title: L("Stop Temp Basal"), text: error.localizedDescription)
            }
        }
    }

    func suspend() {
        run(.suspend, title: L("Suspend insulin")) { done in self.manager.suspend(completion: done) }
    }

    func resume() {
        run(.resume, title: L("Resume insulin")) { done in self.manager.resume(completion: done) }
    }

    func syncTime() {
        busyAction = .syncTime
        manager.syncTime { result in
            DispatchQueue.main.async {
                self.busyAction = nil
                switch result {
                case .success:
                    self.resultMessage = ResultMessage(title: L("Pump time"), text: L("The pump time was set."))
                case let .failure(error):
                    self.resultMessage = ResultMessage(title: L("Could not set the time"), text: error.localizedDescription)
                }
            }
        }
    }

    func syncBasalProfile() {
        busyAction = .syncBasal
        manager.resyncBasalProfile { result in
            self.busyAction = nil
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
        busyAction = .refresh
        manager.refreshNow { self.busyAction = nil }
    }

    private func run(_ action: Action, title: String, _ work: (@escaping (Error?) -> Void) -> Void) {
        busyAction = action
        work { error in
            self.busyAction = nil
            if let error {
                self.resultMessage = ResultMessage(title: title, text: error.localizedDescription)
            }
        }
    }
}
