@testable import InsightKit
import LoopKit
import XCTest

final class ManagerHarness {
    let client = FakeBridgeClient()
    let delegate = MockPumpDelegate()
    let delegateQueue = DispatchQueue(label: "test.delegate")
    let queue = DispatchQueue(label: "test.manager")
    let scheduler = ManualScheduler()
    let store = InMemoryCredentialStore()
    var now = Date()
    var manager: InsightPumpManager!

    static func flatSchedule(_ rate: Double = 1.0) -> InsightBasalSchedule {
        InsightBasalSchedule(hourlyRates: Array(repeating: rate, count: 24))!
    }

    init(configure: (inout InsightPumpManagerState) -> Void = { _ in }) {
        var state = InsightPumpManagerState(bridgeId: "b", bridgeName: "InsightBridge-1234", peripheralIdentifier: nil)
        state.isOnboarded = true
        state.basalSchedule = Self.flatSchedule()
        state.basalScheduleSynced = true
        state.pumpSerial = "SN1"
        state.operatingMode = .started
        state.pumpTimeZoneOffsetSeconds = TimeZone.current.secondsFromGMT()
        state.insulinType = .novolog
        state.limits = PumpLimitsState(maxBolus: 10, maxBasal: 5, bolusStep: 0.05, basalStep: 0.01, minBasal: 0.02)
        state.lastHistorySequence = 100
        state.reservoirUnits = 100
        configure(&state)
        client.status = status()
        manager = InsightPumpManager(
            state: state, client: client, credentialStore: store, queue: queue, scheduler: scheduler,
            clock: { [weak self] in self?.now ?? Date() }
        )
        manager.pumpManagerDelegate = delegate
        manager.delegateQueue = delegateQueue
        settle()
    }

    /// A status as the bridge would report it `seconds` after the harness clock.
    func status(
        after seconds: TimeInterval = 1, mode: PumpOperatingMode = .started, tbr: BridgeStatus.TBR? = nil,
        boluses: [BridgeStatus.ActiveBolus] = [], basalRate: Double? = 1.0, reservoir: Double = 100,
        alert: BridgeAlert? = nil, historySequence: Int? = 100, serial: String = "SN1"
    ) -> BridgeStatus {
        BridgeStatus(
            timestamp: now.addingTimeInterval(seconds), pumpLink: .connected, serial: serial, firmware: "1.0",
            operatingMode: mode,
            battery: .init(percent: 80), reservoir: .init(units: reservoir, cartridgeType: nil),
            basal: .init(activeProfile: 1, rate: basalRate), tbr: tbr, boluses: boluses,
            pumpTime: .init(utc: now, pumpLocal: nil, driftSeconds: 0),
            limits: .init(maxBolus: 10, maxBasal: 5, bolusStep: 0.05, basalStep: 0.01, minBasal: 0.02),
            activeAlert: alert, lastHistorySequence: historySequence
        )
    }

    func settle() {
        for _ in 0 ..< 8 {
            queue.sync {}
            delegateQueue.sync {}
        }
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        queue.sync { scheduler.advance(by: seconds) }
        settle()
    }

    var state: InsightPumpManagerState { manager.state }

    private func wait<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        body { value = $0
            semaphore.signal() }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success, "completion not called")
        settle()
        return value!
    }

    func bolus(_ units: Double, decision: UUID? = nil, activation: BolusActivationType = .automatic) -> PumpManagerError? {
        wait { done in manager.enactBolus(decisionId: decision, units: units, activationType: activation, completion: done) }
    }

    func tbr(_ rate: Double, minutes: Double = 30, decision: UUID? = nil) -> PumpManagerError? {
        wait { done in manager.enactTempBasal(decisionId: decision, unitsPerHour: rate, for: minutes * 60, completion: done) }
    }

    func suspend() -> Error? { wait { done in manager.suspendDelivery(completion: done) } }
    func resume() -> Error? { wait { done in manager.resumeDelivery(completion: done) } }

    func cancelBolus() -> PumpManagerResult<DoseEntry?> {
        wait { done in manager.cancelBolus(completion: done) }
    }

    func syncSchedule(_ items: [RepeatingScheduleValue<Double>]) -> Result<BasalRateSchedule, Error> {
        wait { done in manager.syncBasalRateSchedule(items: items, completion: done) }
    }

    func ensureData() { _ = wait { (done: @escaping (Date?) -> Void) in manager.ensureCurrentPumpData(completion: done) } }

    /// Makes the next bolus time out and returns the manager in the uncertain state.
    func makeBolusUncertain(_ units: Double = 1.0) {
        client.bolusResult = .failure(.timeout)
        XCTAssertEqual(bolus(units).map { "\($0)" }, "\(PumpManagerError.uncertainDelivery)")
    }

    func historyEvent(_ seq: Int, _ type: String, after seconds: TimeInterval, _ data: String) -> HistoryEvent {
        HistoryEvent(seq: seq, time: now.addingTimeInterval(seconds), type: type, data: json(data))
    }
}

func isUncertain(_ error: PumpManagerError?) -> Bool {
    if case .uncertainDelivery? = error { return true }
    return false
}
