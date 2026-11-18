import Foundation

public typealias BridgeResult<T> = Result<T, BridgeError>

public protocol InsightBridgeClientDelegate: AnyObject {
    func bridgeClientDidChangeState(_ client: InsightBridgeClient)
    func bridgeClient(_ client: InsightBridgeClient, didReceive event: BridgeEvent)
}

/// Typed operations of §5.1. The manager only talks to this protocol, so tests can substitute a fake.
public protocol InsightBridgeClient: AnyObject {
    var delegate: InsightBridgeClientDelegate? { get set }
    var sessionState: BridgeSessionState { get }
    var hello: HelloResult? { get }
    /// A (so far unconfirmed) `sessionReject` was seen: the bridge may need to be paired again.
    var repairSuspected: Bool { get }

    /// Start connecting to the paired bridge and keep the session alive.
    func start(bridgeId: String, peripheral: UUID?)
    func stop()
    func ensureStarted()

    func getStatus(_ completion: @escaping (BridgeResult<BridgeStatus>) -> Void)
    func deliverBolus(amount: Double, requestId: String, _ completion: @escaping (BridgeResult<DeliverBolusResult>) -> Void)
    func cancelBolus(bolusId: Int, _ completion: @escaping (BridgeResult<CancelBolusResult>) -> Void)
    func setTBR(percent: Int, duration: Int, requestId: String, _ completion: @escaping (BridgeResult<SetTBRResult>) -> Void)
    func cancelTBR(requestId: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void)
    func setOperatingMode(
        _ mode: PumpOperatingModeCommand,
        requestId: String,
        _ completion: @escaping (BridgeResult<OperatingModeResult>) -> Void
    )
    func setBasalProfile(
        segments: [BasalSegment],
        requestId: String,
        _ completion: @escaping (BridgeResult<SetBasalProfileResult>) -> Void
    )
    func setDateTime(utc: Date, tzOffsetMinutes: Int, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void)
    func readHistory(since: Int?, max: Int, _ completion: @escaping (BridgeResult<HistoryResult>) -> Void)
    func confirmAlert(alertId: Int, alertType: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void)
    func snoozeAlert(alertId: Int, alertType: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void)
    func pumpPairingStatus(_ completion: @escaping (BridgeResult<PumpPairingStatusResult>) -> Void)
    /// Asks what happened to an earlier dosing request (never resends it).
    func getRequestOutcome(requestId: String, _ completion: @escaping (BridgeResult<RequestOutcomeResult>) -> Void)

    // Setup
    func startScan(delegate: BridgeScanDelegate)
    func stopScan()
    func beginPairing(peripheral: UUID, handler: @escaping (PairingEvent) -> Void)
    func confirmPairingCode(matches: Bool)
    func cancelPairing()
}

public final class SessionBridgeClient: InsightBridgeClient, BridgeSessionDelegate {
    public weak var delegate: InsightBridgeClientDelegate?
    public let session: BridgeSession
    private let scanner: BridgeScanning?

    public init(session: BridgeSession, scanner: BridgeScanning? = nil) {
        self.session = session
        self.scanner = scanner
        session.delegate = self
    }

    public func startScan(delegate: BridgeScanDelegate) {
        scanner?.scanDelegate = delegate
        scanner?.startScan()
    }

    public func stopScan() { scanner?.stopScan() }

    public func beginPairing(peripheral: UUID, handler: @escaping (PairingEvent) -> Void) {
        session.beginPairing(peripheral: peripheral, handler: handler)
    }

    public func confirmPairingCode(matches: Bool) { session.confirmPairingCode(matches: matches) }
    public func cancelPairing() { session.cancelPairing() }

    public var sessionState: BridgeSessionState { session.state }
    public var hello: HelloResult? { session.hello }
    public var repairSuspected: Bool { session.repairSuspected }

    public func start(bridgeId: String, peripheral: UUID?) { session.start(bridgeId: bridgeId, peripheral: peripheral) }
    public func stop() { session.stop() }
    public func ensureStarted() { session.ensureStarted() }

    // MARK: BridgeSessionDelegate

    public func sessionDidChangeState(_: BridgeSession) {
        delegate?.bridgeClientDidChangeState(self)
    }

    public func session(_: BridgeSession, didReceive event: BridgeEvent) {
        delegate?.bridgeClient(self, didReceive: event)
    }

    // MARK: ops

    private func call<A: Encodable, R: Decodable>(
        _ op: BridgeOp, _ args: A, _ completion: @escaping (BridgeResult<R>) -> Void
    ) {
        session.send(op, args: args) { result in
            switch result {
            case let .success(value):
                do { completion(.success(try BridgeJSON.decode(R.self, from: value))) }
                catch {
                    // The command was accepted by the bridge protocol-wise but the answer is unreadable:
                    // for dosing ops the outcome is unknown.
                    let err = error as? BridgeError ?? .decoding(op.rawValue)
                    completion(.failure(
                        op
                            .isDosing ?
                            .remote(BridgeRemoteError(code: .internal, message: err.localizedDescription, uncertain: true)) : err
                    ))
                }
            case let .failure(error):
                // A protocol/decoding problem on a dosing op is an unknown outcome, not a clean failure.
                switch error {
                case .decoding,
                     .protocolViolation:
                    completion(.failure(
                        op.isDosing
                            ? .remote(BridgeRemoteError(code: .internal, message: error.localizedDescription, uncertain: true))
                            : error
                    ))
                default:
                    completion(.failure(error))
                }
            }
        }
    }

    public func getStatus(_ completion: @escaping (BridgeResult<BridgeStatus>) -> Void) {
        call(.getStatus, EmptyArgs(), completion)
    }

    public func deliverBolus(
        amount: Double,
        requestId: String,
        _ completion: @escaping (BridgeResult<DeliverBolusResult>) -> Void
    ) {
        call(.deliverBolus, DeliverBolusArgs(amount: amount, requestId: requestId), completion)
    }

    public func cancelBolus(bolusId: Int, _ completion: @escaping (BridgeResult<CancelBolusResult>) -> Void) {
        call(.cancelBolus, CancelBolusArgs(bolusId: bolusId), completion)
    }

    public func setTBR(
        percent: Int,
        duration: Int,
        requestId: String,
        _ completion: @escaping (BridgeResult<SetTBRResult>) -> Void
    ) {
        call(.setTBR, SetTBRArgs(percent: percent, duration: duration, requestId: requestId), completion)
    }

    public func cancelTBR(requestId: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        call(.cancelTBR, RequestIdArgs(requestId: requestId), completion)
    }

    public func setOperatingMode(
        _ mode: PumpOperatingModeCommand,
        requestId: String,
        _ completion: @escaping (BridgeResult<OperatingModeResult>) -> Void
    ) {
        call(.setOperatingMode, SetOperatingModeArgs(mode: mode, requestId: requestId), completion)
    }

    public func setBasalProfile(
        segments: [BasalSegment],
        requestId: String,
        _ completion: @escaping (BridgeResult<SetBasalProfileResult>) -> Void
    ) {
        call(.setBasalProfile, SetBasalProfileArgs(segments: segments, requestId: requestId), completion)
    }

    public func setDateTime(utc: Date, tzOffsetMinutes: Int, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        call(.setDateTime, SetDateTimeArgs(utc: utc, tzOffsetMinutes: tzOffsetMinutes), completion)
    }

    public func readHistory(since: Int?, max: Int, _ completion: @escaping (BridgeResult<HistoryResult>) -> Void) {
        call(.readHistory, ReadHistoryArgs(sinceSequence: since, max: max), completion)
    }

    public func confirmAlert(alertId: Int, alertType: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        call(.confirmAlert, AlertRefArgs(alertId: alertId, alertType: alertType), completion)
    }

    public func snoozeAlert(alertId: Int, alertType: String, _ completion: @escaping (BridgeResult<EmptyResult>) -> Void) {
        call(.snoozeAlert, AlertRefArgs(alertId: alertId, alertType: alertType), completion)
    }

    public func getRequestOutcome(requestId: String, _ completion: @escaping (BridgeResult<RequestOutcomeResult>) -> Void) {
        call(.getRequestOutcome, RequestIdArgs(requestId: requestId), completion)
    }

    public func pumpPairingStatus(_ completion: @escaping (BridgeResult<PumpPairingStatusResult>) -> Void) {
        call(.pumpPairingStatus, EmptyArgs(), completion)
    }
}
