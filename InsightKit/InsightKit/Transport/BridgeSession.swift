import CryptoKit
import Foundation

public enum BridgeSessionState: Equatable {
    /// Not started.
    case idle
    case bluetoothUnavailable(String)
    case linkConnecting
    /// Link is up, `sessionStart`/`hello` in progress.
    case handshaking
    case ready
    /// The bridge does not know this phone / failed verification. Needs re-pairing; no auto-reconnect.
    case needsRepair(String)
    /// Protocol version mismatch.
    case incompatible
    /// Pairing flow in progress (link is up).
    case pairing
}

public protocol BridgeSessionDelegate: AnyObject {
    func sessionDidChangeState(_ session: BridgeSession)
    func session(_ session: BridgeSession, didReceive event: BridgeEvent)
}

public enum PairingEvent: Equatable {
    /// `pairStart` sent; waiting for the bridge to answer.
    case waitingForBridge
    /// Show this code on both devices; call `confirmPairingCode(matches:)`.
    case confirmCode(String)
    /// The user confirmed on iOS; waiting for the Android confirmation.
    case waitingForBridgeConfirmation
    case completed(bridgeId: String)
    case failed(BridgeError)
}

/// Session layer: handshake (§4), envelope crypto (§3), request/response correlation with timeouts,
/// events. Everything runs on `queue`; public methods may be called from any queue.
public final class BridgeSession: BridgeLinkDelegate {
    private struct Pending {
        let op: BridgeOp
        let completion: (Result<BridgeValue, BridgeError>) -> Void
        var timer: BridgeCancellable?
    }

    private struct Waiting {
        let op: BridgeOp
        let args: BridgeValue
        let completion: (Result<BridgeValue, BridgeError>) -> Void
        var timer: BridgeCancellable?
        let token: UInt64
    }

    private struct PairingContext {
        let privateKey: P256.KeyAgreement.PrivateKey
        let nonceI: Data
        let clientId: String
        var nonceB: Data?
        var bridgeId: String?
        var ltk: SymmetricKey?
        var confirmed = false
        var revealed = false
    }

    private let link: BridgeLink
    private let store: BridgeCredentialStoring
    private let scheduler: BridgeScheduler
    private let queue: DispatchQueue
    private let appName: String
    private let log = InsightLog(category: "BridgeSession")

    public weak var delegate: BridgeSessionDelegate?

    // `state`, `hello` and `repairSuspected` are read from other threads (manager status, UI): lock-protected.
    private let publishedLock = NSLock()
    private var _state: BridgeSessionState = .idle
    private var _hello: HelloResult?
    private var _repairSuspected = false

    public private(set) var state: BridgeSessionState {
        get { publishedLock.lock()
            defer { publishedLock.unlock() }
            return _state }
        set { publishedLock.lock()
            _state = newValue
            publishedLock.unlock() }
    }

    public private(set) var hello: HelloResult? {
        get { publishedLock.lock()
            defer { publishedLock.unlock() }
            return _hello }
        set { publishedLock.lock()
            _hello = newValue
            publishedLock.unlock() }
    }

    /// An unauthenticated `sessionReject` was seen once; it is only believed when it repeats.
    public private(set) var repairSuspected: Bool {
        get { publishedLock.lock()
            defer { publishedLock.unlock() }
            return _repairSuspected }
        set { publishedLock.lock()
            _repairSuspected = newValue
            publishedLock.unlock() }
    }

    private var rejectRetry: BridgeCancellable?

    /// The bridge this session talks to (credentials looked up in the store).
    public private(set) var bridgeId: String?

    private var codec: EnvelopeCodec?
    private var nextRequestId: UInt32 = 1
    private var pending = [UInt32: Pending]()
    private var waiting = [Waiting]()
    private var waitingToken: UInt64 = 0
    private var handshakeTimer: BridgeCancellable?
    private var credentials: BridgeCredentials?
    private var sessionNonceI: Data?
    private var pairing: PairingContext?
    private var pairingTimer: BridgeCancellable?
    private var pairingHandler: ((PairingEvent) -> Void)?
    private var wantsConnection = false

    public init(
        link: BridgeLink,
        store: BridgeCredentialStoring,
        scheduler: BridgeScheduler,
        queue: DispatchQueue,
        appName: String
    ) {
        self.link = link
        self.store = store
        self.scheduler = scheduler
        self.queue = queue
        self.appName = appName
        link.delegate = self
    }

    // MARK: lifecycle

    /// Start (and keep) a session with an already paired bridge.
    public func start(bridgeId: String, peripheral: UUID?) {
        queue.async {
            self.bridgeId = bridgeId
            self.credentials = self.store.load(bridgeId: bridgeId)
            self.link.targetPeripheral = peripheral
            self.wantsConnection = true
            self.repairSuspected = false
            guard self.credentials != nil else {
                self.setState(.needsRepair("missing credentials"))
                return
            }
            if case .needsRepair = self.state { self.state = .idle }
            self.startLinkIfNeeded()
        }
    }

    /// Reconnect after a long pause, e.g. when the app returns to the foreground.
    public func ensureStarted() {
        queue.async {
            guard self.wantsConnection else { return }
            if case .needsRepair = self.state { return }
            if case .incompatible = self.state { return }
            self.link.start()
        }
    }

    public func stop() {
        queue.async {
            self.wantsConnection = false
            self.rejectRetry?.cancel()
            self.rejectRetry = nil
            self.teardownConnection(error: .notConnected, newState: .idle)
            self.link.stop()
        }
    }

    private func startLinkIfNeeded() {
        switch link.state {
        case .connected:
            if state != .ready, state != .handshaking { beginSession() }
        case .connecting:
            setState(.linkConnecting)
        case let .bluetoothUnavailable(reason):
            setState(.bluetoothUnavailable(reason))
        case .stopped:
            setState(.linkConnecting)
            link.start()
        }
    }

    var isReady: Bool { state == .ready }

    // MARK: commands

    /// Sends `op`. If the session is not ready the command waits up to `connectWait` for it; if the
    /// session never comes up the result is `.notConnected` (nothing was sent, so this is certain).
    public func send(
        _ op: BridgeOp,
        args: BridgeValue = .object([:]),
        connectWait: TimeInterval = BridgeProtocol.connectWait,
        completion: @escaping (Result<BridgeValue, BridgeError>) -> Void
    ) {
        queue.async {
            switch self.state {
            case .ready:
                self.transmit(op, args: args, completion: completion)
            case let .needsRepair(reason):
                completion(.failure(.sessionRejected(reason)))
            case .incompatible:
                completion(.failure(.unsupportedProtocol))
            case .pairing:
                completion(.failure(.notConnected))
            case .bluetoothUnavailable,
                 .handshaking,
                 .idle,
                 .linkConnecting:
                guard self.wantsConnection else {
                    completion(.failure(.notConnected))
                    return
                }
                self.enqueueWaiting(op, args: args, connectWait: connectWait, completion: completion)
                self.link.start()
            }
        }
    }

    public func send<A: Encodable>(
        _ op: BridgeOp,
        args: A,
        connectWait: TimeInterval = BridgeProtocol.connectWait,
        completion: @escaping (Result<BridgeValue, BridgeError>) -> Void
    ) {
        do {
            send(op, args: try BridgeJSON.toValue(args), connectWait: connectWait, completion: completion)
        } catch {
            completion(.failure(error as? BridgeError ?? .encoding(op.rawValue)))
        }
    }

    private func enqueueWaiting(
        _ op: BridgeOp, args: BridgeValue, connectWait: TimeInterval,
        completion: @escaping (Result<BridgeValue, BridgeError>) -> Void
    ) {
        waitingToken &+= 1
        let token = waitingToken
        var entry = Waiting(op: op, args: args, completion: completion, timer: nil, token: token)
        entry.timer = scheduler.schedule(after: connectWait) { [weak self] in
            guard let self, let idx = self.waiting.firstIndex(where: { $0.token == token }) else { return }
            let w = self.waiting.remove(at: idx)
            w.completion(.failure(.notConnected))
        }
        waiting.append(entry)
    }

    private func flushWaiting() {
        let items = waiting
        waiting = []
        for w in items {
            w.timer?.cancel()
            transmit(w.op, args: w.args, completion: w.completion)
        }
    }

    private func failWaiting(_ error: BridgeError) {
        let items = waiting
        waiting = []
        for w in items {
            w.timer?.cancel()
            w.completion(.failure(error))
        }
    }

    private func transmit(_ op: BridgeOp, args: BridgeValue, completion: @escaping (Result<BridgeValue, BridgeError>) -> Void) {
        guard codec != nil else {
            completion(.failure(.notConnected))
            return
        }
        let id = nextRequestId
        nextRequestId &+= 1
        let request: BridgeValue = .object(["id": .number(Double(id)), "op": .string(op.rawValue), "args": args])

        let envelope: Data
        do {
            let json = try BridgeJSON.encoder.encode(request)
            envelope = try codec!.seal(json)
        } catch {
            // Nothing left the phone.
            completion(.failure(.encoding(op.rawValue)))
            return
        }

        var entry = Pending(op: op, completion: completion, timer: nil)
        entry.timer = scheduler.schedule(after: op.timeout) { [weak self] in
            self?.requestTimedOut(id)
        }
        pending[id] = entry

        link.send(envelope) { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async {
                // The envelope may or may not have arrived completely. Treat as lost link.
                self.log.warning("send failed for \(op.rawValue)")
                self.handleLinkProblem(.linkLost, resetLink: true)
            }
        }
    }

    private func requestTimedOut(_ id: UInt32) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        log.warning("request \(entry.op.rawValue) timed out")
        entry.completion(.failure(.timeout))
        // The link may be half-open: drop it and reconnect.
        handleLinkProblem(.linkLost, resetLink: true)
    }

    // MARK: state / teardown

    private func setState(_ new: BridgeSessionState) {
        guard state != new else { return }
        state = new
        delegate?.sessionDidChangeState(self)
    }

    private func failAllPending(_ error: BridgeError) {
        let items = pending
        pending = [:]
        for (_, p) in items {
            p.timer?.cancel()
            p.completion(.failure(error))
        }
    }

    private func teardownConnection(error: BridgeError, newState: BridgeSessionState) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        codec = nil
        hello = nil
        sessionNonceI = nil
        // Requests that were already transmitted may have been executed: they fail as "link lost" (uncertain),
        // never as a clean rejection. Only requests that never left the phone fail with `error`.
        failAllPending(.linkLost)
        failWaiting(error)
        setState(newState)
    }

    /// Drops the encrypted session after a fault and reconnects (unless re-pairing is required).
    private func handleLinkProblem(_ error: BridgeError, resetLink: Bool) {
        let hadSession = codec != nil || state == .handshaking
        log.warning("link problem: \(String(describing: error))")
        handshakeTimer?.cancel()
        handshakeTimer = nil
        codec = nil
        hello = nil
        // Whatever the reason: requests that were already sent may have been executed, so they fail as
        // "link lost" (an uncertain outcome) and never as a clean rejection.
        failAllPending(.linkLost)
        if hadSession, wantsConnection {
            setState(.linkConnecting)
        }
        if resetLink, wantsConnection { link.reset() }
    }

    // MARK: link delegate

    public func linkDidChangeState(_: BridgeLink) {
        queue.async { self.handleLinkState() }
    }

    private func handleLinkState() {
        switch link.state {
        case .connected:
            if pairing != nil {
                beginPairingExchange()
            } else if wantsConnection {
                if case .needsRepair = state { return }
                if state == .ready || state == .handshaking { return }
                beginSession()
            }
        case .connecting:
            if pairing != nil { return }
            codec = nil
            failAllPending(.linkLost)
            if wantsConnection, !isTerminal { setState(.linkConnecting) }
        case let .bluetoothUnavailable(reason):
            codec = nil
            failAllPending(.linkLost)
            if pairing != nil {
                finishPairing(.failed(.bluetoothUnavailable(reason)))
            } else if wantsConnection {
                setState(.bluetoothUnavailable(reason))
            }
        case .stopped:
            codec = nil
            failAllPending(.linkLost)
            if pairing == nil, wantsConnection, !isTerminal { setState(.linkConnecting) }
        }
    }

    private var isTerminal: Bool {
        switch state {
        case .incompatible,
             .needsRepair: return true
        default: return false
        }
    }

    public func link(_: BridgeLink, didReceive envelope: Data) {
        queue.async { self.handleEnvelope(envelope) }
    }

    private func handleEnvelope(_ envelope: Data) {
        if EnvelopeCodec.isEncrypted(envelope) {
            handleEncrypted(envelope)
        } else if let message = HandshakeMessage.decode(envelope) {
            handleHandshake(message)
        } else {
            log.warning("dropping malformed envelope")
        }
    }

    // MARK: encrypted messages

    private func handleEncrypted(_ envelope: Data) {
        guard codec != nil else {
            log.warning("encrypted message without session")
            return
        }
        let plain: Data
        do {
            plain = try codec!.open(envelope)
        } catch {
            // Replay or tampering: never process, drop the link.
            log.error("envelope rejected: \(String(describing: error))")
            handleLinkProblem(.protocolViolation("envelope"), resetLink: true)
            return
        }
        guard let value = try? BridgeJSON.decoder.decode(BridgeValue.self, from: plain) else {
            log.warning("undecodable message")
            return
        }
        if let evt = value["evt"]?.stringValue {
            handleEvent(evt, data: value["data"] ?? .null)
        } else if let id = value["id"]?.doubleValue, id >= 0, id <= Double(UInt32.max) {
            handleResponse(UInt32(id), value)
        } else if let error = value["error"], let remote = try? BridgeJSON.decode(BridgeRemoteError.self, from: error) {
            // e.g. error.tooLarge without a request id
            log.warning("bridge error without id: \(remote.code.rawValue)")
        }
    }

    private func handleResponse(_ id: UInt32, _ value: BridgeValue) {
        guard let entry = pending.removeValue(forKey: id) else {
            log.info("response for unknown/expired request \(id)")
            return
        }
        entry.timer?.cancel()
        if value["ok"]?.boolValue == true {
            entry.completion(.success(value["result"] ?? .object([:])))
        } else if let errValue = value["error"], let remote = try? BridgeJSON.decode(BridgeRemoteError.self, from: errValue) {
            entry.completion(.failure(.remote(remote)))
        } else if entry.op.isDosing {
            // A dosing answer we cannot read says nothing about what the pump did.
            entry
                .completion(.failure(.remote(BridgeRemoteError(
                    code: .internal,
                    message: "unreadable response",
                    uncertain: true
                ))))
        } else {
            entry.completion(.failure(.protocolViolation("response")))
        }
    }

    private func handleEvent(_ name: String, data: BridgeValue) {
        let event: BridgeEvent
        do {
            switch name {
            case "status": event = .status(try BridgeJSON.decode(BridgeStatus.self, from: data))
            case "alert": event = .alert(try BridgeJSON.decode(BridgeAlert.self, from: data))
            case "bolusProgress": event = .bolusProgress(try BridgeJSON.decode(BolusProgress.self, from: data))
            case "pumpLink":
                let raw = data["state"]?.stringValue ?? ""
                event = .pumpLink(PumpLinkState(rawValue: raw) ?? .unknown)
            default: event = .unknown(name)
            }
        } catch {
            log.warning("undecodable event \(name)")
            return
        }
        delegate?.session(self, didReceive: event)
    }

    // MARK: session handshake

    private func beginSession() {
        guard let bridgeId, let creds = credentials ?? store.load(bridgeId: bridgeId) else {
            setState(.needsRepair("missing credentials"))
            return
        }
        credentials = creds
        let nonce = Self.randomBytes(16)
        sessionNonceI = nonce
        codec = nil
        setState(.handshaking)
        do {
            let envelope = try HandshakeMessage.encode(HandshakeMessage.sessionStart(clientId: creds.clientId, nonce: nonce))
            link.send(envelope) { [weak self] error in
                guard error != nil, let self else { return }
                self.queue.async { self.handleLinkProblem(.linkLost, resetLink: true) }
            }
        } catch {
            handleLinkProblem(.encoding("sessionStart"), resetLink: false)
            return
        }
        handshakeTimer?.cancel()
        handshakeTimer = scheduler.schedule(after: BridgeProtocol.pairingResponseTimeout) { [weak self] in
            guard let self, self.state == .handshaking else { return }
            self.log.warning("handshake timed out")
            self.handleLinkProblem(.timeout, resetLink: true)
        }
    }

    private func handleHandshake(_ message: [String: Any]) {
        guard let type = message["t"] as? String else { return }
        switch type {
        case "sessionResp": handleSessionResp(message)
        case "sessionReject":
            handleSessionReject(message["reason"] as? String ?? "rejected")
        case "pairResp": handlePairResp(message)
        case "pairDone": handlePairDone(message)
        case "pairReject":
            let reason = message["reason"] as? String ?? "rejected"
            if pairing != nil { finishPairing(.failed(.pairingRejected(reason))) }
        default:
            log.info("ignoring handshake message \(type)")
        }
    }

    /// `sessionReject` is plaintext and unauthenticated, so anybody in radio range could send one. A single
    /// reject only raises a suspicion and reconnects later; it takes a second reject on a separate connection
    /// before the pairing is declared broken.
    private func handleSessionReject(_ reason: String) {
        guard state == .handshaking else { return }
        log.warning("session rejected: \(reason)")
        if repairSuspected {
            rejectRetry?.cancel()
            rejectRetry = nil
            teardownConnection(error: .sessionRejected(reason), newState: .needsRepair(reason))
            link.stop()
            return
        }
        repairSuspected = true
        teardownConnection(error: .notConnected, newState: .linkConnecting)
        rejectRetry?.cancel()
        rejectRetry = scheduler.schedule(after: BridgeProtocol.sessionRejectRetryDelay) { [weak self] in
            guard let self, self.wantsConnection else { return }
            self.rejectRetry = nil
            self.link.reset()
        }
    }

    private func handleSessionResp(_ message: [String: Any]) {
        guard state == .handshaking, let creds = credentials, let nonceI = sessionNonceI,
              let nonceB = HandshakeMessage.data(message, "nonce", count: 16),
              let mac = HandshakeMessage.data(message, "mac")
        else {
            log.warning("unexpected/invalid sessionResp")
            return
        }
        if let responded = message["bridgeId"] as? String, responded.lowercased() != creds.bridgeId.lowercased() {
            teardownConnection(error: .macMismatch, newState: .needsRepair("bridge identity changed"))
            link.stop()
            return
        }
        let ltk = SymmetricKey(data: creds.ltk)
        let expected = BridgeKDF.sessionMac(ltk: ltk, nonceI: nonceI, nonceB: nonceB)
        guard BridgeKDF.verify(mac: mac, expected: expected) else {
            log.error("session MAC mismatch")
            teardownConnection(error: .macMismatch, newState: .needsRepair("verification failed"))
            link.stop()
            return
        }
        let sk = BridgeKDF.sessionKey(ltk: ltk, nonceI: nonceI, nonceB: nonceB)
        codec = EnvelopeCodec(sessionKey: sk)
        sessionNonceI = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil

        // First encrypted message: hello (must arrive within 10 s on the bridge side).
        let args = (try? BridgeJSON.toValue(HelloArgs(app: appName))) ?? .object([:])
        transmit(.hello, args: args) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(value):
                guard let hello = try? BridgeJSON.decode(HelloResult.self, from: value) else {
                    self.handleLinkProblem(.decoding("hello"), resetLink: true)
                    return
                }
                guard hello.protocolVersion == BridgeProtocol.version else {
                    self.log.error("bridge speaks protocol \(String(describing: hello.protocolVersion))")
                    self.teardownConnection(error: .unsupportedProtocol, newState: .incompatible)
                    self.link.stop()
                    return
                }
                self.hello = hello
                self.repairSuspected = false
                self.setState(.ready)
                self.flushWaiting()
            case let .failure(error):
                if case let .remote(remote) = error, remote.code == .unsupportedProtocol {
                    self.teardownConnection(error: .unsupportedProtocol, newState: .incompatible)
                    self.link.stop()
                } else if case let .remote(remote) = error, remote.code == .busy {
                    self.teardownConnection(error: error, newState: .needsRepair("bridge busy"))
                    self.link.stop()
                } else {
                    self.log.warning("hello failed")
                    self.handleLinkProblem(error, resetLink: true)
                }
            }
        }
    }

    // MARK: pairing (§4.1)

    /// Starts the pairing handshake with the bridge at `peripheral`. Any existing session is dropped.
    public func beginPairing(peripheral: UUID, handler: @escaping (PairingEvent) -> Void) {
        queue.async {
            self.wantsConnection = false
            self.teardownConnection(error: .notConnected, newState: .pairing)
            self.pairingHandler = handler
            self.pairing = PairingContext(
                privateKey: P256.KeyAgreement.PrivateKey(),
                nonceI: Self.randomBytes(16),
                clientId: Self.randomBytes(8).hexString
            )
            self.link.targetPeripheral = peripheral
            if self.link.state == .connected {
                self.beginPairingExchange()
            } else {
                self.link.start()
            }
        }
    }

    public func cancelPairing() {
        queue.async {
            guard self.pairing != nil else { return }
            if let data = try? HandshakeMessage.encode(HandshakeMessage.pairReject(reason: "userRejected")),
               self.link.state == .connected
            {
                self.link.send(data) { _ in }
            }
            self.finishPairing(.failed(.pairingRejected("userRejected")))
        }
    }

    /// The user answers "codes match" (true) or "cancel" (false).
    public func confirmPairingCode(matches: Bool) {
        queue.async {
            guard var ctx = self.pairing, let ltk = ctx.ltk else { return }
            guard matches else {
                self.cancelPairing()
                return
            }
            ctx.confirmed = true
            self.pairing = ctx
            do {
                let env = try HandshakeMessage.encode(HandshakeMessage.pairConfirm(mac: BridgeKDF.confirmMacPhone(ltk: ltk)))
                self.link.send(env) { [weak self] error in
                    if error != nil { self?.queue.async { self?.finishPairing(.failed(.linkLost)) } }
                }
                self.pairingHandler?(.waitingForBridgeConfirmation)
                self.armPairingTimer(BridgeProtocol.pairingConfirmTimeout)
            } catch {
                self.finishPairing(.failed(.encoding("pairConfirm")))
            }
        }
    }

    private func beginPairingExchange() {
        guard let ctx = pairing, ctx.ltk == nil else { return }
        do {
            // v2: only a commitment goes out first; the values are revealed after the bridge answered.
            let commit = BridgeKDF.commitment(publicKey: ctx.privateKey.publicKey.x963Representation, nonce: ctx.nonceI)
            let env = try HandshakeMessage.encode(HandshakeMessage.pairStart(commit: commit))
            link.send(env) { [weak self] error in
                if error != nil { self?.queue.async { self?.finishPairing(.failed(.linkLost)) } }
            }
            pairingHandler?(.waitingForBridge)
            armPairingTimer(BridgeProtocol.pairingResponseTimeout)
        } catch {
            finishPairing(.failed(.encoding("pairStart")))
        }
    }

    private func armPairingTimer(_ interval: TimeInterval) {
        pairingTimer?.cancel()
        pairingTimer = scheduler.schedule(after: interval) { [weak self] in
            self?.finishPairing(.failed(.timeout))
        }
    }

    private func handlePairResp(_ message: [String: Any]) {
        guard var ctx = pairing, ctx.ltk == nil,
              let pub = HandshakeMessage.data(message, "pub"),
              let nonceB = HandshakeMessage.data(message, "nonce", count: 16),
              let bridgeId = message["bridgeId"] as? String, !bridgeId.isEmpty
        else {
            if pairing != nil { finishPairing(.failed(.protocolViolation("pairResp"))) }
            return
        }
        do {
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: pub)
            let secret = try ctx.privateKey.sharedSecretFromKeyAgreement(with: peer)
            let ltk = BridgeKDF.longTermKey(sharedSecret: secret, nonceI: ctx.nonceI, nonceB: nonceB)
            ctx.nonceB = nonceB
            ctx.bridgeId = bridgeId
            ctx.ltk = ltk
            ctx.revealed = true
            pairing = ctx
            let reveal = try HandshakeMessage.encode(
                HandshakeMessage.pairReveal(publicKey: ctx.privateKey.publicKey.x963Representation, nonce: ctx.nonceI)
            )
            link.send(reveal) { [weak self] error in
                if error != nil { self?.queue.async { self?.finishPairing(.failed(.linkLost)) } }
            }
            armPairingTimer(BridgeProtocol.pairingConfirmTimeout)
            pairingHandler?(.confirmCode(BridgeKDF.sas(ltk: ltk)))
        } catch {
            finishPairing(.failed(.protocolViolation("pairResp key")))
        }
    }

    private func handlePairDone(_ message: [String: Any]) {
        guard let ctx = pairing, ctx.confirmed, let ltk = ctx.ltk, let bridgeId = ctx.bridgeId,
              let mac = HandshakeMessage.data(message, "mac")
        else {
            // pairDone before the user confirmed here is never accepted.
            if pairing != nil { finishPairing(.failed(.protocolViolation("pairDone"))) }
            return
        }
        guard BridgeKDF.verify(mac: mac, expected: BridgeKDF.confirmMacBridge(ltk: ltk)) else {
            finishPairing(.failed(.macMismatch))
            return
        }
        let ltkData = ltk.withUnsafeBytes { Data($0) }
        do {
            try store.save(BridgeCredentials(bridgeId: bridgeId, ltk: ltkData, clientId: ctx.clientId))
        } catch {
            finishPairing(.failed(.protocolViolation("could not store key")))
            return
        }
        self.bridgeId = bridgeId
        credentials = nil
        finishPairing(.completed(bridgeId: bridgeId))
    }

    private func finishPairing(_ event: PairingEvent) {
        pairingTimer?.cancel()
        pairingTimer = nil
        let handler = pairingHandler
        pairing = nil
        pairingHandler = nil
        if case .failed = event, state == .pairing { setState(.idle) }
        handler?(event)
    }

    /// After a successful pairing: begin a normal session on the (still connected) link.
    public func startAfterPairing(peripheral: UUID) {
        guard let bridgeId else { return }
        start(bridgeId: bridgeId, peripheral: peripheral)
    }

    // MARK: helpers

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}
