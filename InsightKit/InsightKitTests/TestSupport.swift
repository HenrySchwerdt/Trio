import CryptoKit
import Foundation
@testable import InsightKit
import LoopKit

// MARK: - Manual scheduler

final class ManualScheduler: BridgeScheduler {
    private final class Token: BridgeCancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private struct Item { let due: TimeInterval
        let token: Token
        let block: () -> Void }

    private let lock = NSLock()
    private var items = [Item]()
    private(set) var now: TimeInterval = 0

    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> BridgeCancellable {
        lock.lock()
        defer { lock.unlock() }
        let token = Token()
        items.append(Item(due: now + interval, token: token, block: block))
        return token
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { !$0.token.cancelled }.count
    }

    /// Advances time and runs due blocks (call from the queue the blocks expect).
    func advance(by interval: TimeInterval) {
        lock.lock()
        now += interval
        let due = items.filter { $0.due <= now && !$0.token.cancelled }.sorted { $0.due < $1.due }
        items.removeAll { $0.due <= now || $0.token.cancelled }
        lock.unlock()
        for item in due { item.block() }
    }
}

// MARK: - Fake link + fake bridge (bridge side of the protocol)

final class FakeLink: BridgeLink {
    weak var delegate: BridgeLinkDelegate?
    var state: BridgeLinkState = .stopped { didSet { delegate?.linkDidChangeState(self) } }
    var targetPeripheral: UUID?
    private(set) var sent = [Data]()
    private(set) var resetCount = 0
    private(set) var startCount = 0
    var onSend: ((Data) -> Void)?
    var failSends = false

    func start() { startCount += 1 }
    func stop() { state = .stopped }
    func reset() { resetCount += 1 }

    func send(_ envelope: Data, completion: @escaping (Error?) -> Void) {
        sent.append(envelope)
        if failSends { completion(BridgeError.linkLost)
            return }
        completion(nil)
        onSend?(envelope)
    }

    func deliver(_ envelope: Data) { delegate?.link(self, didReceive: envelope) }
}

enum FakeReply {
    case ok(BridgeValue)
    case error(code: String, uncertain: Bool)
    case silent
}

/// Implements the bridge side of §3/§4 on top of a FakeLink.
final class FakeBridge {
    let link: FakeLink
    let bridgeId = "00112233aabbccdd"
    let ltk: SymmetricKey
    var handler: (String, BridgeValue) -> FakeReply = { _, _ in .ok(.object([:])) }
    var helloReply: FakeReply = .ok(json(#"{"protocol":2,"bridgeVersion":"test","pumpPaired":true}"#))
    private(set) var requests = [(op: String, args: BridgeValue)]()
    private var codec: EnvelopeCodec?
    var rejectSession = false
    var corruptMac = false

    init(link: FakeLink, ltk: SymmetricKey = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))) {
        self.link = link
        self.ltk = ltk
        link.onSend = { [weak self] data in self?.receive(data) }
    }

    func count(_ op: String) -> Int { requests.filter { $0.op == op }.count }

    private func receive(_ envelope: Data) {
        if EnvelopeCodec.isEncrypted(envelope) {
            guard var codec else { return }
            guard let plain = try? codec.open(envelope) else { self.codec = codec
                return }
            self.codec = codec
            guard let json = try? JSONDecoder().decode(BridgeValue.self, from: plain),
                  let id = json["id"]?.doubleValue, let op = json["op"]?.stringValue else { return }
            let args = json["args"] ?? .object([:])
            requests.append((op, args))
            switch op == "hello" ? helloReply : handler(op, args) {
            case let .ok(result):
                respond(.object(["id": .number(id), "ok": .bool(true), "result": result]))
            case let .error(code, uncertain):
                respond(.object([
                    "id": .number(id), "ok": .bool(false),
                    "error": .object(["code": .string(code), "message": .string("x"), "uncertain": .bool(uncertain)])
                ]))
            case .silent:
                break
            }
        } else if let message = HandshakeMessage.decode(envelope), message["t"] as? String == "sessionStart" {
            if rejectSession {
                link.deliver((try? HandshakeMessage.encode(["t": "sessionReject", "reason": "unknownClient"])) ?? Data())
                return
            }
            guard let nonceI = HandshakeMessage.data(message, "nonce", count: 16) else { return }
            let nonceB = Data((0 ..< 16).map { UInt8(0xA0 + $0) })
            var mac = BridgeKDF.sessionMac(ltk: ltk, nonceI: nonceI, nonceB: nonceB)
            if corruptMac { mac[0] ^= 0xFF }
            let sk = BridgeKDF.sessionKey(ltk: ltk, nonceI: nonceI, nonceB: nonceB)
            codec = EnvelopeCodec(sessionKey: sk, sendDirection: .bridgeToPhone)
            link.deliver((try? HandshakeMessage.encode([
                "t": "sessionResp", "v": 2, "bridgeId": bridgeId,
                "nonce": nonceB.base64EncodedString(), "mac": mac.base64EncodedString()
            ])) ?? Data())
        }
    }

    private(set) var lastEnvelope: Data?

    func respond(_ value: BridgeValue) {
        guard var codec, let data = try? JSONEncoder().encode(value), let env = try? codec.seal(data) else { return }
        self.codec = codec
        lastEnvelope = env
        link.deliver(env)
    }

    /// Encrypts a message with the current session without delivering it.
    func seal(_ value: BridgeValue) -> Data? {
        guard var codec, let data = try? JSONEncoder().encode(value), let env = try? codec.seal(data) else { return nil }
        self.codec = codec
        return env
    }

    func sendEvent(_ name: String, _ data: BridgeValue) {
        respond(.object(["evt": .string(name), "data": data]))
    }
}

// MARK: - JSON helpers

func json(_ string: String) -> BridgeValue {
    try! JSONDecoder().decode(BridgeValue.self, from: Data(string.utf8))
}

func date(_ iso: String) -> Date { BridgeDate.parse(iso)! }

// MARK: - Fake client (op level) for manager tests

final class FakeBridgeClient: InsightBridgeClient {
    weak var delegate: InsightBridgeClientDelegate?
    var sessionState: BridgeSessionState = .ready
    var hello: HelloResult? = HelloResult(protocolVersion: 2, bridgeVersion: "test", pumpPaired: true)
    var repairSuspected = false
    var outcomeResult: BridgeResult<RequestOutcomeResult> = .success(RequestOutcomeResult(state: .unknown))
    private(set) var outcomeCalls = [String]()
    /// When set, `deliverBolus` does not answer until `releaseBolus` is called.
    var holdBolus = false
    private var heldBolus: (() -> Void)?
    func releaseBolus() { heldBolus?()
        heldBolus = nil }

    var status = BridgeStatus(
        timestamp: Date(),
        serial: "SN1",
        firmware: "1.0",
        battery: .init(percent: 80),
        reservoir: .init(units: 100, cartridgeType: nil),
        basal: .init(activeProfile: 1, rate: 1.0),
        limits: .init(maxBolus: 10, maxBasal: 5, bolusStep: 0.05, basalStep: 0.01, minBasal: 0.02),
        lastHistorySequence: 100
    )
    var statusResult: BridgeResult<BridgeStatus>?
    var history = [HistoryEvent]()
    var historyResult: BridgeResult<HistoryResult>?
    /// Takes precedence over `history`/`historyResult` (called with `since`).
    var historyHandler: ((Int?) -> BridgeResult<HistoryResult>)?
    var onSetProfile: (() -> Void)?
    /// nil: the bridge echoes the requested amount (bolus id 7)
    var bolusResult: BridgeResult<DeliverBolusResult>?
    var cancelBolusResult: BridgeResult<CancelBolusResult> = .success(CancelBolusResult(delivered: 0.5))
    var tbrResult: BridgeResult<SetTBRResult>?
    var cancelTbrResult: BridgeResult<EmptyResult> = .success(EmptyResult())
    var modeResult: BridgeResult<OperatingModeResult>?
    var profileResult: BridgeResult<SetBasalProfileResult> = .success(SetBasalProfileResult(activeProfile: 1))

    private(set) var deliverBolusCalls = [(amount: Double, requestId: String)]()
    private(set) var setTbrCalls = [(percent: Int, duration: Int, requestId: String)]()
    private(set) var cancelTbrCalls = 0
    private(set) var modeCalls = [PumpOperatingModeCommand]()
    private(set) var profileCalls = [[BasalSegment]]()
    private(set) var statusCalls = 0
    private(set) var historyCalls = [Int?]()
    private(set) var confirmedAlerts = [Int]()
    private(set) var timeCalls = 0

    func start(bridgeId _: String, peripheral _: UUID?) {}
    func stop() {}
    func ensureStarted() {}

    func getStatus(_ completion: @escaping (BridgeResult<BridgeStatus>) -> Void) {
        statusCalls += 1
        completion(statusResult ?? .success(status))
    }

    func deliverBolus(amount: Double, requestId: String, _ completion: @escaping (BridgeResult<DeliverBolusResult>) -> Void) {
        deliverBolusCalls.append((amount, requestId))
        if holdBolus {
            let answer = bolusResult ?? .success(DeliverBolusResult(bolusId: 7, amount: amount))
            heldBolus = { completion(answer) }
            return
        }
        completion(bolusResult ?? .success(DeliverBolusResult(bolusId: 7, amount: amount)))
    }

    private(set) var cancelBolusIds = [Int]()

    func cancelBolus(bolusId: Int, _ completion: @escaping (BridgeResult<CancelBolusResult>) -> Void) {
        cancelBolusIds.append(bolusId)
        completion(cancelBolusResult)
    }

    func setTBR(percent: Int, duration: Int, requestId: String, _ completion: @escaping (BridgeResult<SetTBRResult>) -> Void) {
        setTbrCalls.append((percent, duration, requestId))
        completion(tbrResult ?? .success(SetTBRResult(percent: percent, duration: duration)))
    }

    func cancelTBR(requestId _: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        cancelTbrCalls += 1
        completion(cancelTbrResult)
    }

    func setOperatingMode(
        _ mode: PumpOperatingModeCommand,
        requestId _: String,
        _ completion: @escaping (BridgeResult<OperatingModeResult>) -> Void
    ) {
        modeCalls.append(mode)
        completion(modeResult ?? .success(OperatingModeResult(mode: mode.rawValue)))
    }

    func setBasalProfile(
        segments: [BasalSegment],
        requestId _: String,
        _ completion: @escaping (BridgeResult<SetBasalProfileResult>) -> Void
    ) {
        profileCalls.append(segments)
        onSetProfile?()
        completion(profileResult)
    }

    func setDateTime(utc _: Date, tzOffsetMinutes _: Int, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        timeCalls += 1
        completion(.success(EmptyResult()))
    }

    func readHistory(since: Int?, max _: Int, _ completion: @escaping (BridgeResult<HistoryResult>) -> Void) {
        historyCalls.append(since)
        if let historyHandler { completion(historyHandler(since))
            return }
        if let historyResult { completion(historyResult)
            return }
        let events = history.filter { $0.seq > (since ?? -1) }
        completion(.success(HistoryResult(events: events, lastSequence: history.map(\.seq).max() ?? 0, more: false)))
    }

    func confirmAlert(alertId: Int, alertType _: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        confirmedAlerts.append(alertId)
        completion(.success(EmptyResult()))
    }

    func snoozeAlert(alertId _: Int, alertType _: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        completion(.success(EmptyResult())) }

    func getRequestOutcome(requestId: String, _ completion: @escaping (BridgeResult<RequestOutcomeResult>) -> Void) {
        outcomeCalls.append(requestId)
        completion(outcomeResult)
    }

    func pumpPairingStatus(_ completion: @escaping (BridgeResult<PumpPairingStatusResult>) -> Void) {
        completion(.success(PumpPairingStatusResult(paired: true, serial: "SN1", bridgeBluetoothOn: true)))
    }

    func startScan(delegate _: BridgeScanDelegate) {}
    func stopScan() {}
    func beginPairing(peripheral _: UUID, handler _: @escaping (PairingEvent) -> Void) {}
    func confirmPairingCode(matches _: Bool) {}
    func cancelPairing() {}
}

// MARK: - Pump manager delegate mock

nonisolated final class MockPumpDelegate: PumpManagerDelegate {
    private let lock = NSLock()
    private var _events = [[NewPumpEvent]]()
    private var _replace = [Bool]()
    var failEvents = false
    /// The delegate never answers `hasNewPumpEvents`.
    var stallEvents = false
    /// Called inside `pumpManagerDidUpdateState` (to simulate a delegate that talks back to the manager).
    var onStateUpdate: (() -> Void)?
    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { true }
    var automatedTreatmentState: AutomatedTreatmentState? { nil }

    var eventBatches: [[NewPumpEvent]] { lock.lock()
        defer { lock.unlock() }
        return _events }

    var allEvents: [NewPumpEvent] { eventBatches.flatMap { $0 } }
    var replaceFlags: [Bool] { lock.lock()
        defer { lock.unlock() }
        return _replace }

    private(set) var issuedAlerts = [Alert]()
    private(set) var retractedAlerts = [Alert.Identifier]()
    private(set) var reservoirReads = [Double]()
    private(set) var stateUpdates = 0

    func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {}
    func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool { false }
    func pumpManagerWantsDeletion(_: PumpManager) async {}
    func pumpManagerPumpWasReplaced(_: PumpManager) {}
    func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}
    func pumpManager(_: PumpManager, didError _: PumpManagerError) {}
    func pumpManager(
        _: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation _: Date?,
        replacePendingEvents: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        lock.lock()
        _events.append(events)
        _replace.append(replacePendingEvents)
        lock.unlock()
        if stallEvents { return }
        completion(failEvents ? NSError(domain: "test", code: 1) : nil)
    }

    func pumpManager(
        _: PumpManager,
        didReadReservoirValue units: Double,
        at _: Date,
        completion _: @escaping (Result<
            (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool),
            Error
        >) -> Void
    ) {
        lock.lock()
        reservoirReads.append(units)
        lock.unlock()
    }

    func pumpManager(_: PumpManager, didAdjustPumpClockBy _: TimeInterval) {}
    func pumpManagerDidUpdateState(_: PumpManager) {
        lock.lock()
        stateUpdates += 1
        lock.unlock()
        onStateUpdate?()
    }

    func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) { completion(nil) }
    @MainActor func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date { Date().addingTimeInterval(-3600 * 24) }
    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {}
    func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type _: DeviceLogEntryType,
        message _: String,
        completion: ((Error?) -> Void)?
    ) { completion?(nil) }
    @MainActor func issueAlert(_ alert: Alert) async { lock.lock()
        issuedAlerts.append(alert)
        lock.unlock() }

    @MainActor func retractAlert(identifier: Alert.Identifier) async { lock.lock()
        retractedAlerts.append(identifier)
        lock.unlock() }

    func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_: Alert, at _: Date) async throws {}
}

extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
