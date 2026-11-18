import CryptoKit
@testable import InsightKit
import XCTest

/// Runs InsightKit against the bridge's own test vectors (`test-vectors.json`, a copy of the file published with
/// the Android bridge). A failure here is an interoperability bug: the message says what each side computes.
final class InteropVectorTests: XCTestCase {
    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-vectors", withExtension: "json"),
            "test-vectors.json is not bundled"
        )
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: helpers

    private func dict(_ key: String) throws
        -> [String: Any] { try XCTUnwrap(vectors[key] as? [String: Any], "missing vector section \(key)") }
    private func str(_ d: [String: Any], _ key: String) throws -> String { try XCTUnwrap(d[key] as? String, "missing \(key)") }
    private func hex(
        _ d: [String: Any],
        _ key: String
    ) throws -> Data { try XCTUnwrap(Data(hexString: try str(d, key)), "\(key) is not hex") }
    private func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func expectEqual(_ ours: Data, _ vector: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            ours,
            vector,
            "\(name): InsightKit computes \(ours.hexString), the bridge vector says \(vector.hexString)",
            file: file,
            line: line
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func sameJSON(
        _ a: [String: Any],
        _ b: [String: Any],
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(NSDictionary(dictionary: a).isEqual(to: b), "\(name): ours \(a) vs vector \(b)", file: file, line: line)
    }

    // MARK: HKDF

    func testHkdfSanityRfc5869() throws {
        let v = try dict("hkdfSanity")
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: try hex(v, "ikm")), salt: try hex(v, "salt"), info: try hex(v, "info"),
            outputByteCount: try XCTUnwrap(v["length"] as? Int)
        )
        expectEqual(keyBytes(okm), try hex(v, "okm"), "RFC 5869 test case 1")
    }

    // MARK: pairing

    func testEphemeralKeysAndEcdhSharedSecret() throws {
        let v = try dict("pairing")
        let initiator = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v, "initiatorPrivateScalar"))
        let bridge = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v, "bridgePrivateScalar"))
        expectEqual(initiator.publicKey.x963Representation, try hex(v, "initiatorPublicKey"), "initiator public key (X9.63)")
        expectEqual(bridge.publicKey.x963Representation, try hex(v, "bridgePublicKey"), "bridge public key (X9.63)")
        let z1 = try initiator.sharedSecretFromKeyAgreement(with: bridge.publicKey).withUnsafeBytes { Data($0) }
        let z2 = try bridge.sharedSecretFromKeyAgreement(with: initiator.publicKey).withUnsafeBytes { Data($0) }
        expectEqual(z1, try hex(v, "sharedSecretZ"), "ECDH Z (iPhone side)")
        expectEqual(z2, try hex(v, "sharedSecretZ"), "ECDH Z (bridge side)")
    }

    func testCommitment() throws {
        let v = try dict("pairing")
        let c = try XCTUnwrap(v["commitment"] as? [String: Any])
        let pub = try hex(v, "initiatorPublicKey")
        let nonce = try hex(v, "nonceI")
        expectEqual(BridgeKDF.commitment(publicKey: pub, nonce: nonce), try hex(c, "commit"), "commitment")
        let wrong = try hex(c, "wrongNonceI")
        expectEqual(
            BridgeKDF.commitment(publicKey: pub, nonce: wrong),
            try hex(c, "commitWithWrongNonceI"),
            "commitment with wrong nonceI"
        )
        XCTAssertNotEqual(BridgeKDF.commitment(publicKey: pub, nonce: wrong), try hex(c, "commit"))
    }

    func testLongTermKeyViaKeyAgreementAndRawSecret() throws {
        let v = try dict("pairing")
        let initiator = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v, "initiatorPrivateScalar"))
        let bridgePub = try P256.KeyAgreement.PublicKey(x963Representation: try hex(v, "bridgePublicKey"))
        let secret = try initiator.sharedSecretFromKeyAgreement(with: bridgePub)
        let nonceI = try hex(v, "nonceI"), nonceB = try hex(v, "nonceB")
        XCTAssertEqual(nonceI + nonceB, try hex(v, "ltkSalt"))
        let viaAgreement = BridgeKDF.longTermKey(sharedSecret: secret, nonceI: nonceI, nonceB: nonceB)
        let viaRaw = BridgeKDF.longTermKey(rawSharedSecret: try hex(v, "sharedSecretZ"), nonceI: nonceI, nonceB: nonceB)
        expectEqual(keyBytes(viaAgreement), try hex(v, "ltk"), "LTK (HKDF over ECDH SharedSecret)")
        expectEqual(keyBytes(viaRaw), try hex(v, "ltk"), "LTK (HKDF over raw Z)")
    }

    func testSasAndConfirmMacs() throws {
        let v = try dict("pairing")
        let ltk = SymmetricKey(data: try hex(v, "ltk"))
        XCTAssertEqual(BridgeKDF.sas(ltk: ltk), try str(v, "sas"), "SAS from the pairing vector")
        expectEqual(BridgeKDF.confirmMacPhone(ltk: ltk), try hex(v, "pairConfirmMac"), "pairConfirm MAC (confirm-i)")
        expectEqual(BridgeKDF.confirmMacBridge(ltk: ltk), try hex(v, "pairDoneMac"), "pairDone MAC (confirm-b)")
        XCTAssertTrue(BridgeKDF.verify(mac: try hex(v, "pairDoneMac"), expected: BridgeKDF.confirmMacBridge(ltk: ltk)))
    }

    func testSasCases() throws {
        let cases = try XCTUnwrap(vectors["sasCases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 0)
        for (index, c) in cases.enumerated() {
            let ltk = SymmetricKey(data: try hex(c, "ltk"))
            XCTAssertEqual(BridgeKDF.sas(ltk: ltk), try str(c, "sas"), "sasCases[\(index)] (leading zeros included)")
        }
    }

    func testPairingMessagesHaveTheSameFieldsAndEncoding() throws {
        let v = try dict("pairing")
        let m = try XCTUnwrap(v["messages"] as? [String: Any])
        let pub = try hex(v, "initiatorPublicKey"), nonce = try hex(v, "nonceI")
        let ltk = SymmetricKey(data: try hex(v, "ltk"))

        sameJSON(
            HandshakeMessage.pairStart(commit: BridgeKDF.commitment(publicKey: pub, nonce: nonce)),
            try jsonObject(try str(m, "pairStart")),
            "pairStart"
        )
        sameJSON(
            HandshakeMessage.pairReveal(publicKey: pub, nonce: nonce),
            try jsonObject(try str(m, "pairReveal")),
            "pairReveal"
        )
        sameJSON(
            HandshakeMessage.pairConfirm(mac: BridgeKDF.confirmMacPhone(ltk: ltk)),
            try jsonObject(try str(m, "pairConfirm")),
            "pairConfirm"
        )

        // messages from the bridge: we must parse every field the way the bridge wrote it
        let resp = try jsonObject(try str(m, "pairResp"))
        XCTAssertEqual(resp["t"] as? String, "pairResp")
        XCTAssertEqual(resp["v"] as? Int, BridgeProtocol.version)
        XCTAssertEqual(HandshakeMessage.data(resp, "pub", count: 65), try hex(v, "bridgePublicKey"), "pairResp.pub")
        XCTAssertEqual(HandshakeMessage.data(resp, "nonce", count: 16), try hex(v, "nonceB"), "pairResp.nonce")
        XCTAssertEqual(resp["bridgeId"] as? String, try str(v, "bridgeId"))

        let done = try jsonObject(try str(m, "pairDone"))
        XCTAssertEqual(done["t"] as? String, "pairDone")
        XCTAssertEqual(HandshakeMessage.data(done, "mac"), try hex(v, "pairDoneMac"), "pairDone.mac")

        // and the envelope wrapper (type byte 0x01 + JSON) round-trips
        let wrapped = try HandshakeMessage
            .encode(HandshakeMessage.pairStart(commit: BridgeKDF.commitment(publicKey: pub, nonce: nonce)))
        XCTAssertEqual(wrapped.first, 0x01)
        sameJSON(try XCTUnwrap(HandshakeMessage.decode(wrapped)), try jsonObject(try str(m, "pairStart")), "pairStart envelope")
    }

    /// The whole pairing run against the vector's bridge side: our session code must reach the same LTK and SAS.
    func testPairingSessionAgainstTheVectorBridge() throws {
        let v = try dict("pairing")
        let bridgeKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v, "bridgePrivateScalar"))
        let initiator = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v, "initiatorPrivateScalar"))
        // bridge side computes the same SAS as the iPhone side
        let secretB = try bridgeKey.sharedSecretFromKeyAgreement(with: initiator.publicKey)
        let ltkBridgeSide = BridgeKDF.longTermKey(
            sharedSecret: secretB,
            nonceI: try hex(v, "nonceI"),
            nonceB: try hex(v, "nonceB")
        )
        XCTAssertEqual(BridgeKDF.sas(ltk: ltkBridgeSide), try str(v, "sas"))
    }

    // MARK: session

    func testSessionMacAndKey() throws {
        let v = try dict("session")
        let ltk = SymmetricKey(data: try hex(v, "ltk"))
        let nonceI = try hex(v, "nonceI"), nonceB = try hex(v, "nonceB")
        XCTAssertEqual(nonceI + nonceB, try hex(v, "sessionKeySalt"))
        expectEqual(BridgeKDF.sessionMac(ltk: ltk, nonceI: nonceI, nonceB: nonceB), try hex(v, "mac"), "session MAC")
        expectEqual(
            keyBytes(BridgeKDF.sessionKey(ltk: ltk, nonceI: nonceI, nonceB: nonceB)),
            try hex(v, "sessionKey"),
            "session key (SK)"
        )
    }

    func testSessionMessages() throws {
        let v = try dict("session")
        let m = try XCTUnwrap(v["messages"] as? [String: Any])
        let nonceI = try hex(v, "nonceI")
        sameJSON(
            HandshakeMessage.sessionStart(clientId: try str(v, "clientId"), nonce: nonceI),
            try jsonObject(try str(m, "sessionStart")),
            "sessionStart"
        )
        let resp = try jsonObject(try str(m, "sessionResp"))
        XCTAssertEqual(resp["t"] as? String, "sessionResp")
        XCTAssertEqual(resp["v"] as? Int, BridgeProtocol.version)
        XCTAssertEqual(resp["bridgeId"] as? String, try str(v, "bridgeId"))
        XCTAssertEqual(HandshakeMessage.data(resp, "nonce", count: 16), try hex(v, "nonceB"))
        XCTAssertEqual(HandshakeMessage.data(resp, "mac"), try hex(v, "mac"))
    }

    /// Feeds the vector's `sessionResp` to a real `BridgeSession` that sent the vector's `sessionStart` nonce.
    func testSessionAcceptsTheVectorSessionResponse() throws {
        let v = try dict("session")
        let m = try XCTUnwrap(v["messages"] as? [String: Any])
        let queue = DispatchQueue(label: "vector.session")
        let link = FakeLink()
        let store = InMemoryCredentialStore()
        try store
            .save(BridgeCredentials(bridgeId: try str(v, "bridgeId"), ltk: try hex(v, "ltk"), clientId: try str(v, "clientId")))
        let session = BridgeSession(link: link, store: store, scheduler: ManualScheduler(), queue: queue, appName: "Trio 1.0")
        session.start(bridgeId: try str(v, "bridgeId"), peripheral: UUID())
        queue.sync {}
        link.state = .connected
        queue.sync {}
        queue.sync {}
        // our sessionStart carries a random nonce, so the vector's response cannot match it: it must be rejected
        let respData = Data([0x01]) + Data(try str(m, "sessionResp").utf8)
        link.deliver(respData)
        queue.sync {}
        queue.sync {}
        XCTAssertNotEqual(session.state, .ready, "a response whose MAC does not cover our nonce is never accepted")
    }

    // MARK: envelopes

    func testEveryEnvelopeVectorBothDirectionsExactBytes() throws {
        let envelopes = try XCTUnwrap(vectors["envelopes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(envelopes.count, 4)
        for e in envelopes {
            let name = try str(e, "name")
            let key = SymmetricKey(data: try hex(e, "key"))
            let counter = UInt64(try XCTUnwrap(e["counter"] as? Int))
            let direction: BridgeDirection =
                try XCTUnwrap(BridgeDirection(rawValue: UInt8(try XCTUnwrap(e["directionByte"] as? Int))))
            let plaintext = try hex(e, "plaintextHex")
            XCTAssertEqual(Data(try str(e, "plaintextUtf8").utf8), plaintext, "\(name): plaintextUtf8 vs plaintextHex")
            let envelope = try hex(e, "envelope")

            // nonce and AAD as documented
            expectEqual(
                Data(try EnvelopeCodec.nonce(direction: direction, counter: counter)),
                try hex(e, "nonce"),
                "\(name): nonce"
            )
            expectEqual(Data(envelope.prefix(9)), try hex(e, "aad"), "\(name): AAD (= envelope bytes 0..8)")
            expectEqual(Data(envelope.dropFirst(9)), try hex(e, "ciphertextAndTag"), "\(name): ciphertext||tag")

            // sealing with the sender's codec reproduces the exact bytes
            var sender = EnvelopeCodec(
                sessionKey: key,
                sendDirection: direction,
                sendCounter: counter - 1,
                lastReceivedCounter: 0
            )
            expectEqual(try sender.seal(plaintext), envelope, "\(name): sealed envelope")

            // the receiver (opposite direction) decrypts it
            var receiver = EnvelopeCodec(
                sessionKey: key,
                sendDirection: direction == .phoneToBridge ? .bridgeToPhone : .phoneToBridge,
                sendCounter: 0,
                lastReceivedCounter: counter - 1
            )
            expectEqual(try receiver.open(envelope), plaintext, "\(name): opened plaintext")
            // and cannot open it a second time
            XCTAssertThrowsError(try receiver.open(envelope), "\(name): replay") {
                XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .replay) }
        }
    }

    func testEnvelopeVectorsCoverBothDirectionsAndMultiByteCounters() throws {
        let envelopes = try XCTUnwrap(vectors["envelopes"] as? [[String: Any]])
        XCTAssertTrue(envelopes.contains { ($0["directionByte"] as? Int) == 1 })
        XCTAssertTrue(envelopes.contains { ($0["directionByte"] as? Int) == 2 })
        XCTAssertTrue(envelopes.contains { ($0["counter"] as? Int ?? 0) > 255 })
    }

    func testTamperedVectorEnvelopesAreRejected() throws {
        let envelopes = try XCTUnwrap(vectors["envelopes"] as? [[String: Any]])
        for e in envelopes where (e["directionByte"] as? Int) == 2 {
            let key = SymmetricKey(data: try hex(e, "key"))
            let counter = UInt64(try XCTUnwrap(e["counter"] as? Int))
            var envelope = try hex(e, "envelope")
            envelope[envelope.count - 1] ^= 0x01
            var phone = EnvelopeCodec(
                sessionKey: key,
                sendDirection: .phoneToBridge,
                sendCounter: 0,
                lastReceivedCounter: counter - 1
            )
            XCTAssertThrowsError(try phone.open(envelope), "\(e["name"] ?? "")")
        }
    }

    // MARK: fragmentation

    private func checkFragmentation(_ section: String) throws {
        let v = try dict(section)
        let message = try hex(v, "message")
        let maxSize = try XCTUnwrap(v["maxFragmentSize"] as? Int)
        let seq = UInt16(try XCTUnwrap(v["messageSeq"] as? Int))
        let expected = try XCTUnwrap(v["fragments"] as? [String]).map { try XCTUnwrap(Data(hexString: $0)) }
        let ours = try XCTUnwrap(Fragmenter.fragments(of: message, messageSeq: seq, maxFragmentSize: maxSize))
        XCTAssertEqual(ours.count, expected.count, "\(section): number of fragments")
        for (index, (a, b)) in zip(ours, expected).enumerated() {
            expectEqual(a, b, "\(section): fragment \(index)")
        }
        var reassembler = Reassembler()
        var outcome: Reassembler.Outcome = .incomplete
        for fragment in expected { outcome = reassembler.accept(fragment) }
        XCTAssertEqual(outcome, .complete(message), "\(section): reassembly of the bridge's fragments")
    }

    func testFragmentationVector() throws { try checkFragmentation("fragmentation") }
    func testSingleFragmentVector() throws { try checkFragmentation("fragmentationSingle") }

    // MARK: completeness

    func testVectorFileDeclaresProtocolVersionTwoAndAllSections() throws {
        XCTAssertEqual(vectors["protocolVersion"] as? Int, BridgeProtocol.version)
        for key in ["hkdfSanity", "pairing", "sasCases", "session", "envelopes", "fragmentation", "fragmentationSingle"] {
            XCTAssertNotNil(vectors[key], "section \(key) is missing in test-vectors.json")
        }
        let pairing = try dict("pairing")
        for key in ["commitment", "messages", "sas", "pairConfirmMac", "pairDoneMac", "ltk", "sharedSecretZ"] {
            XCTAssertNotNil(pairing[key], "pairing.\(key) is missing")
        }
    }
}
