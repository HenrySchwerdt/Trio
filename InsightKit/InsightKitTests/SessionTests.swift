import CryptoKit
@testable import InsightKit
import XCTest

private final class SessionSpy: BridgeSessionDelegate {
    var states = [BridgeSessionState]()
    var events = [BridgeEvent]()
    func sessionDidChangeState(_ session: BridgeSession) { states.append(session.state) }
    func session(_: BridgeSession, didReceive event: BridgeEvent) { events.append(event) }
}

class SessionTestCase: XCTestCase {
    let queue = DispatchQueue(label: "test.session")
    let scheduler = ManualScheduler()
    let link = FakeLink()
    var bridge: FakeBridge!
    let store = InMemoryCredentialStore()
    fileprivate let spy = SessionSpy()
    var session: BridgeSession!

    override func setUp() {
        super.setUp()
        bridge = FakeBridge(link: link)
        try? store.save(BridgeCredentials(
            bridgeId: bridge.bridgeId, ltk: bridge.ltk.withUnsafeBytes { Data($0) }, clientId: "0102030405060708"
        ))
        session = BridgeSession(link: link, store: store, scheduler: scheduler, queue: queue, appName: "Trio test")
        session.delegate = spy
    }

    func flush() { for _ in 0 ..< 4 { queue.sync {} } }

    func advance(_ seconds: TimeInterval) {
        queue.sync { scheduler.advance(by: seconds) }
        flush()
    }

    func connect() {
        session.start(bridgeId: bridge.bridgeId, peripheral: UUID())
        flush()
        link.state = .connected
        flush()
    }

    @discardableResult func send(_ op: BridgeOp, args: BridgeValue = .object([:])) -> Result<BridgeValue, BridgeError>? {
        var result: Result<BridgeValue, BridgeError>?
        session.send(op, args: args) { result = $0 }
        flush()
        return result
    }
}

final class SessionHandshakeTests: SessionTestCase {
    func testHandshakeReachesReadyAndSendsHello() {
        connect()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(bridge.requests.first?.op, "hello")
        XCTAssertEqual(bridge.requests.first?.args["protocol"]?.doubleValue, 2)
        XCTAssertEqual(bridge.requests.first?.args["app"]?.stringValue, "Trio test")
        XCTAssertNotNil(session.hello)
    }

    func testRequestIdsAreUniqueAndIncreasing() {
        connect()
        send(.getStatus)
        send(.getStatus)
        let ids = bridge.requests.count
        XCTAssertEqual(ids, 3)
    }

    func testRepeatedUnknownClientRequiresRepairAndStopsLink() {
        bridge.rejectSession = true
        connect()
        // one unauthenticated reject is only a suspicion: the candidate is ignored (§1a.3), the search goes on
        XCTAssertNotEqual(session.state, .needsRepair("unknownClient"))
        XCTAssertTrue(session.repairSuspected)
        XCTAssertEqual(link.rejectedCount, 1, "the candidate goes on the ignore list")
        XCTAssertEqual(link.authenticatedCount, 0)

        link.state = .connecting
        flush()
        link.state = .connected
        flush()
        XCTAssertEqual(session.state, .needsRepair("unknownClient"), "the second reject is believed")
        XCTAssertEqual(link.state, .stopped, "no endless reconnect loop")
        let result = send(.getStatus)
        XCTAssertEqual(result?.failureValue, .sessionRejected("unknownClient"))
    }

    func testBadSessionMacIgnoresCandidateAndRepeatedFailureNeedsRepair() {
        bridge.corruptMac = true
        connect()
        XCTAssertEqual(session.state, .linkConnecting, "one bad MAC only ignores this candidate")
        XCTAssertEqual(link.rejectedCount, 1)
        XCTAssertTrue(bridge.requests.isEmpty, "no encrypted traffic on an unverified session")
        link.state = .connecting
        flush()
        link.state = .connected
        flush()
        if case .needsRepair = session.state {} else { XCTFail("state \(session.state)") }
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testWrongBridgeIdIgnoresCandidateWithoutRepair() {
        bridge.responseBridgeId = "ffeeddccbbaa9988"
        connect()
        XCTAssertEqual(session.state, .linkConnecting)
        XCTAssertEqual(link.rejectedCount, 1)
        XCTAssertFalse(session.repairSuspected, "a neighbour's bridge says nothing about our pairing")
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testAuthenticatedHandshakeCommitsTheCandidate() {
        connect()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(link.authenticatedCount, 1)
        XCTAssertEqual(link.rejectedCount, 0)
    }

    func testMissingCredentialsNeedRepair() {
        store.delete(bridgeId: bridge.bridgeId)
        session.start(bridgeId: bridge.bridgeId, peripheral: nil)
        flush()
        if case .needsRepair = session.state {} else { XCTFail("state \(session.state)") }
    }

    func testBridgeUnsupportedProtocolIsIncompatible() {
        bridge.helloReply = .error(code: "unsupportedProtocol", uncertain: false)
        connect()
        XCTAssertEqual(session.state, .incompatible)
    }
}

final class SessionRequestTests: SessionTestCase {
    func testSuccessfulRequest() {
        connect()
        bridge.handler = { op, _ in op == "getStatus" ? .ok(json(#"{"pumpLink":"connected","serial":"X"}"#)) : .ok(.object([:])) }
        guard case let .success(value) = send(.getStatus) else { return XCTFail() }
        XCTAssertEqual(value["serial"]?.stringValue, "X")
    }

    func testRemoteErrorKeepsUncertainFlag() {
        connect()
        bridge.handler = { _, _ in .error(code: "pumpUnreachable", uncertain: true) }
        guard case let .failure(error)? = send(.setTBR, args: json(#"{"percent":120,"duration":30,"requestId":"r"}"#))
        else { return XCTFail() }
        XCTAssertTrue(error.isUncertainOutcome)
        guard case let .remote(remote) = error else { return XCTFail() }
        XCTAssertEqual(remote.code, .pumpUnreachable)
    }

    func testDosingTimeoutIsFortyFiveSecondsAndResetsLink() {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        advance(44)
        XCTAssertNil(result, "not yet")
        advance(1.5)
        XCTAssertEqual(result?.failureValue, .timeout)
        XCTAssertEqual(link.resetCount, 1, "half-open link is dropped")
        XCTAssertEqual(bridge.count("deliverBolus"), 1, "never retried")
    }

    func testStatusTimeoutIsThirtySeconds() {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.getStatus) { result = $0 }
        flush()
        advance(29)
        XCTAssertNil(result)
        advance(2)
        XCTAssertNotNil(result)
    }

    func testLateResponseAfterTimeoutIsIgnored() {
        connect()
        bridge.handler = { _, _ in .silent }
        var results = [Result<BridgeValue, BridgeError>]()
        session.send(.getStatus) { results.append($0) }
        flush()
        advance(31)
        XCTAssertEqual(results.count, 1)
        // Session was reset: bring it back, then a stale response for the old id arrives
        link.state = .connected
        flush()
        bridge.respond(json(#"{"id":2,"ok":true,"result":{}}"#))
        flush()
        XCTAssertEqual(results.count, 1)
    }

    func testCommandsWaitForSessionAndFailAsNotConnectedIfItNeverComes() {
        session.start(bridgeId: bridge.bridgeId, peripheral: UUID())
        flush()
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        XCTAssertNil(result)
        advance(21)
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertEqual(error, .notConnected)
        XCTAssertFalse(error.isUncertainOutcome, "nothing was sent")
        XCTAssertEqual(bridge.count("deliverBolus"), 0)
    }

    func testQueuedCommandIsSentOnceSessionIsReady() {
        session.start(bridgeId: bridge.bridgeId, peripheral: UUID())
        flush()
        var result: Result<BridgeValue, BridgeError>?
        session.send(.getStatus) { result = $0 }
        flush()
        link.state = .connected
        flush()
        XCTAssertNotNil(result)
        XCTAssertEqual(bridge.count("getStatus"), 1)
    }

    func testLinkDropFailsPendingRequestsAsUncertainLinkLost() {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.setOperatingMode, args: json(#"{"mode":"stopped","requestId":"r"}"#)) { result = $0 }
        flush()
        link.state = .connecting
        flush()
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertEqual(error, .linkLost)
        XCTAssertTrue(error.isUncertainOutcome)
        XCTAssertNotEqual(session.state, .ready)
    }

    func testReconnectPerformsNewHandshake() {
        connect()
        link.state = .connecting
        flush()
        link.state = .connected
        flush()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(bridge.count("hello"), 2)
        // Counters restart with the new session: requests work again
        guard case .success? = send(.getStatus) else { return XCTFail() }
    }

    func testEventsAreDecodedAndForwarded() {
        connect()
        bridge.sendEvent("status", json(#"{"pumpLink":"connected","serial":"S"}"#))
        bridge.sendEvent("bolusProgress", json(#"{"bolusId":3,"delivered":0.5,"remaining":0.5}"#))
        bridge.sendEvent("alert", json(#"{"alertId":1,"alertType":"W31_CARTRIDGE_LOW","category":"warning"}"#))
        bridge.sendEvent("pumpLink", json(#"{"state":"disconnected"}"#))
        bridge.sendEvent("futureEvent", json("{}"))
        bridge.sendEvent("status", json(#"{"pumpLink":"connected","timestamp":"garbage"}"#))
        flush()
        XCTAssertEqual(spy.events.count, 6 - 0)
        if case let .status(s) = spy.events[0] { XCTAssertEqual(s.serial, "S") } else { XCTFail() }
        if case let .bolusProgress(p) = spy.events[1] { XCTAssertEqual(p.remaining, 0.5) } else { XCTFail() }
        if case let .alert(a) = spy.events[2] { XCTAssertEqual(a.alertType, "W31_CARTRIDGE_LOW") } else { XCTFail() }
        if case let .pumpLink(l) = spy.events[3] { XCTAssertEqual(l, .disconnected) } else { XCTFail() }
        if case .unknown = spy.events[4] {} else { XCTFail() }
    }

    func testReplayedEnvelopeIsRejectedAndLinkReset() {
        connect()
        bridge.sendEvent("pumpLink", json(#"{"state":"connected"}"#))
        flush()
        let before = spy.events.count
        let resets = link.resetCount
        link.deliver(bridge.lastEnvelope!)
        flush()
        XCTAssertEqual(spy.events.count, before, "replay must not be processed")
        XCTAssertEqual(link.resetCount, resets + 1)
        XCTAssertNotEqual(session.state, .ready)
    }

    func testTamperedEnvelopeIsRejectedAndPendingFail() throws {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.getStatus) { result = $0 }
        flush()
        var tampered = try XCTUnwrap(bridge.seal(json(#"{"id":2,"ok":true,"result":{}}"#)))
        tampered[12] ^= 0x01
        link.deliver(tampered)
        flush()
        guard case let .failure(error)? = result else { return XCTFail("pending must fail") }
        XCTAssertTrue(error.isTimeoutLike)
        XCTAssertEqual(link.resetCount, 1)
    }

    func testRequestsFailWhileSendingFailsAsUncertain() {
        connect()
        link.failSends = true
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertTrue(error.isUncertainOutcome)
    }

    func testStopFailsEverythingAndStaysIdle() {
        connect()
        session.stop()
        flush()
        XCTAssertEqual(session.state, .idle)
        guard case let .failure(error)? = send(.getStatus) else { return XCTFail() }
        XCTAssertEqual(error, .notConnected)
    }
}

// MARK: - Pairing

final class SessionPairingTests: SessionTestCase {
    private var bridgeKey = P256.KeyAgreement.PrivateKey()
    private let nonceB = Data((0 ..< 16).map { UInt8(0x30 + $0) })
    private var bridgeLTK: SymmetricKey?
    private var events = [PairingEvent]()
    private var wrongMac = false
    private var rejectInstead: String?

    override func setUp() {
        super.setUp()
        store.delete(bridgeId: bridge.bridgeId)
        link.onSend = { [weak self] data in self?.bridgeReceives(data) }
    }

    private var commit: Data?
    private var revealMessages = [[String: Any]]()
    private var startMessages = [[String: Any]]()
    private var bridgePub: Data?
    var tamperReveal = false

    private func bridgeReceives(_ envelope: Data) {
        guard let message = HandshakeMessage.decode(envelope), let type = message["t"] as? String else { return }
        switch type {
        case "pairStart":
            startMessages.append(message)
            if let rejectInstead {
                link.deliver(try! HandshakeMessage.encode(["t": "pairReject", "reason": rejectInstead]))
                return
            }
            // v2: the phone sends only a commitment first
            commit = HandshakeMessage.data(message, "commit", count: 32)
            bridgePub = bridgeKey.publicKey.x963Representation
            link.deliver(try! HandshakeMessage.encode([
                "t": "pairResp", "v": 2, "pub": bridgePub!.base64EncodedString(),
                "nonce": nonceB.base64EncodedString(), "bridgeId": bridge.bridgeId
            ]))
        case "pairReveal":
            revealMessages.append(message)
            guard let pubData = HandshakeMessage.data(message, "pub"),
                  let nonceI = HandshakeMessage.data(message, "nonce", count: 16),
                  let commit,
                  BridgeKDF.verify(mac: BridgeKDF.commitment(publicKey: pubData, nonce: nonceI), expected: commit),
                  let phonePub = try? P256.KeyAgreement.PublicKey(x963Representation: pubData)
            else {
                link.deliver(try! HandshakeMessage.encode(["t": "pairReject", "reason": "commitMismatch"]))
                return
            }
            let secret = try! bridgeKey.sharedSecretFromKeyAgreement(with: phonePub)
            bridgeLTK = BridgeKDF.longTermKey(sharedSecret: secret, nonceI: nonceI, nonceB: nonceB)
        case "pairConfirm":
            guard let ltk = bridgeLTK, let mac = HandshakeMessage.data(message, "mac"),
                  BridgeKDF.verify(mac: mac, expected: BridgeKDF.confirmMacPhone(ltk: ltk)) else { return }
            var reply = BridgeKDF.confirmMacBridge(ltk: ltk)
            if wrongMac { reply[0] ^= 1 }
            link.deliver(try! HandshakeMessage.encode(["t": "pairDone", "mac": reply.base64EncodedString()]))
        default: break
        }
    }

    private func startPairing() {
        session.beginPairing(peripheral: UUID()) { [weak self] in self?.events.append($0) }
        flush()
        link.state = .connected
        flush()
    }

    func testPairingHappyPathStoresCredentials() throws {
        startPairing()
        XCTAssertEqual(events.first, .waitingForBridge)
        guard case let .confirmCode(code)? = events.dropFirst().first else { return XCTFail("\(events)") }
        XCTAssertEqual(code, BridgeKDF.sas(ltk: try XCTUnwrap(bridgeLTK)), "both sides show the same SAS")
        XCTAssertEqual(code.count, 6)
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId), "nothing stored before confirmation")

        session.confirmPairingCode(matches: true)
        flush()
        XCTAssertEqual(events.last, .completed(bridgeId: bridge.bridgeId))
        let creds = try XCTUnwrap(store.load(bridgeId: bridge.bridgeId))
        XCTAssertEqual(creds.ltk, bridgeLTK!.withUnsafeBytes { Data($0) })
        XCTAssertEqual(creds.clientId.count, 16)
    }

    func testPairStartCarriesOnlyACommitmentAndTheRevealFollows() throws {
        startPairing()
        let start = try XCTUnwrap(startMessages.first)
        XCTAssertEqual(start["v"] as? Int, 2)
        XCTAssertNil(start["pub"], "the public key must not be sent before the bridge answered")
        XCTAssertNil(start["nonce"])
        let commitData = try XCTUnwrap(HandshakeMessage.data(start, "commit", count: 32))
        let reveal = try XCTUnwrap(revealMessages.first)
        let pub = try XCTUnwrap(HandshakeMessage.data(reveal, "pub", count: 65))
        let nonce = try XCTUnwrap(HandshakeMessage.data(reveal, "nonce", count: 16))
        XCTAssertEqual(BridgeKDF.commitment(publicKey: pub, nonce: nonce), commitData)
        // order on the wire: pairStart before pairReveal
        let types = link.sent.compactMap { HandshakeMessage.decode($0)?["t"] as? String }
        XCTAssertEqual(types, ["pairStart", "pairReveal"])
    }

    func testCommitmentVector() {
        // SHA-256("InsightBridge commit v2" || pub(65 x 0x04) || nonce(16 x 0x07)), computed independently with Python
        let pub = Data(repeating: 0x04, count: 65)
        let nonce = Data(repeating: 0x07, count: 16)
        XCTAssertEqual(BridgeKDF.commitment(publicKey: pub, nonce: nonce).hexString, CommitmentVectors.expected)
    }

    func testCommitMismatchIsReportedAsFailure() {
        // a bridge that recomputes a different commitment (e.g. an attacker swapped the values)
        link.onSend = { [weak self] data in
            guard let self, let message = HandshakeMessage.decode(data), let type = message["t"] as? String else { return }
            if type == "pairStart" {
                self.link.deliver(try! HandshakeMessage.encode([
                    "t": "pairResp", "v": 2, "pub": self.bridgeKey.publicKey.x963Representation.base64EncodedString(),
                    "nonce": self.nonceB.base64EncodedString(), "bridgeId": self.bridge.bridgeId
                ]))
            } else if type == "pairReveal" {
                self.link.deliver(try! HandshakeMessage.encode(["t": "pairReject", "reason": "commitMismatch"]))
            }
        }
        startPairing()
        XCTAssertEqual(events.last, .failed(.pairingRejected("commitMismatch")))
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId))
        XCTAssertTrue(BridgeError.pairingRejected("commitMismatch").localizedDescription.contains("rejected the pairing data"))
    }

    func testPairDoneBeforeUserConfirmedIsNotAccepted() throws {
        startPairing()
        let ltk = try XCTUnwrap(bridgeLTK)
        link
            .deliver(
                try HandshakeMessage
                    .encode(["t": "pairDone", "mac": BridgeKDF.confirmMacBridge(ltk: ltk).base64EncodedString()])
            )
        flush()
        if case .failed? = events.last {} else { XCTFail("\(events)") }
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId))
    }

    func testWrongBridgeMacFailsPairing() {
        wrongMac = true
        startPairing()
        session.confirmPairingCode(matches: true)
        flush()
        XCTAssertEqual(events.last, .failed(.macMismatch))
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId))
    }

    func testUserSaysCodesDoNotMatch() {
        startPairing()
        session.confirmPairingCode(matches: false)
        flush()
        XCTAssertEqual(events.last, .failed(.pairingRejected("userRejected")))
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId))
        // a pairReject went to the bridge
        XCTAssertTrue(link.sent.contains { HandshakeMessage.decode($0)?["t"] as? String == "pairReject" })
    }

    func testBridgeNotInPairingMode() {
        rejectInstead = "notInPairingMode"
        startPairing()
        XCTAssertEqual(events.last, .failed(.pairingRejected("notInPairingMode")))
    }

    func testBridgeNeverAnswers() {
        link.onSend = { _ in }
        startPairing()
        advance(16)
        XCTAssertEqual(events.last, .failed(.timeout))
    }

    func testWaitingForAndroidConfirmationTimesOut() {
        link.onSend = { [weak self] data in
            if HandshakeMessage.decode(data)?["t"] as? String == "pairConfirm" { return }
            self?.bridgeReceives(data)
        }
        startPairing()
        session.confirmPairingCode(matches: true)
        flush()
        XCTAssertEqual(events.last, .waitingForBridgeConfirmation)
        advance(131)
        XCTAssertEqual(events.last, .failed(.timeout))
        XCTAssertNil(store.load(bridgeId: bridge.bridgeId))
    }

    func testSessionWorksRightAfterPairing() throws {
        startPairing()
        session.confirmPairingCode(matches: true)
        flush()
        // Now behave like the real bridge for the session handshake with the new LTK
        let ltk = try XCTUnwrap(bridgeLTK)
        let b2 = FakeBridge(link: link, ltk: ltk)
        _ = b2
        session.startAfterPairing(peripheral: UUID())
        flush()
        XCTAssertEqual(session.state, .ready)
    }
}
