import CryptoKit
@testable import InsightKit
import XCTest

final class FragmentationTests: XCTestCase {
    func testSingleFragmentUsesBothFlags() throws {
        let fragments = try XCTUnwrap(Fragmenter.fragments(of: Data([1, 2, 3]), messageSeq: 0x0102, maxFragmentSize: 20))
        XCTAssertEqual(fragments, [Data([0x03, 0x01, 0x02, 1, 2, 3])])
    }

    func testRoundTripWithMinimumMTU() throws {
        // ATT MTU 23 -> 20 byte writes -> 17 byte payload per fragment
        let message = Data((0 ..< 1000).map { UInt8($0 % 251) })
        let fragments = try XCTUnwrap(Fragmenter.fragments(of: message, messageSeq: 7, maxFragmentSize: 20))
        XCTAssertTrue(fragments.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(fragments.first?[0], 0x01)
        XCTAssertEqual(fragments.last?[0], 0x02)
        XCTAssertTrue(fragments.dropFirst().dropLast().allSatisfy { $0[0] == 0x00 })

        var reassembler = Reassembler()
        var result: Reassembler.Outcome = .incomplete
        for f in fragments { result = reassembler.accept(f) }
        XCTAssertEqual(result, .complete(message))
    }

    func testEmptyAndOversizeMessagesAreNotFragmented() {
        XCTAssertNil(Fragmenter.fragments(of: Data(), messageSeq: 1, maxFragmentSize: 20))
        XCTAssertNil(Fragmenter.fragments(of: Data(count: BridgeProtocol.maxMessageSize + 1), messageSeq: 1, maxFragmentSize: 20))
        XCTAssertNotNil(Fragmenter.fragments(of: Data(count: BridgeProtocol.maxMessageSize), messageSeq: 1, maxFragmentSize: 512))
        XCTAssertNil(Fragmenter.fragments(of: Data([1]), messageSeq: 1, maxFragmentSize: 3))
    }

    func testNewFirstFragmentDiscardsPartialMessage() {
        var r = Reassembler()
        XCTAssertEqual(r.accept(Data([0x01, 0, 1, 0xAA])), .incomplete)
        XCTAssertEqual(r.accept(Data([0x03, 0, 2, 0xBB])), .complete(Data([0xBB])))
    }

    func testContinuationWithoutStartAndWrongSeqAreDropped() {
        var r = Reassembler()
        if case .dropped = r.accept(Data([0x02, 0, 1, 0xAA])) {} else { XCTFail("continuation without start must be dropped") }
        XCTAssertEqual(r.accept(Data([0x01, 0, 1, 0xAA])), .incomplete)
        if case .dropped = r.accept(Data([0x02, 0, 9, 0xBB])) {} else { XCTFail("wrong sequence must be dropped") }
        XCTAssertFalse(r.isAssembling)
    }

    func testPartialMessageExpiresAfterFiveSeconds() {
        var r = Reassembler()
        let t0 = Date()
        XCTAssertEqual(r.accept(Data([0x01, 0, 1, 0xAA]), now: t0), .incomplete)
        // LAST fragment arrives too late -> the partial message is gone, the fragment is dropped
        if case .dropped = r.accept(Data([0x02, 0, 1, 0xBB]), now: t0.addingTimeInterval(5.5)) {}
        else { XCTFail("expired message must not complete") }
    }

    func testOversizedIncomingMessageIsRejected() {
        var r = Reassembler(maxSize: 32)
        XCTAssertEqual(r.accept(Data([0x01, 0, 1]) + Data(count: 20)), .incomplete)
        XCTAssertEqual(r.accept(Data([0x00, 0, 1]) + Data(count: 20)), .tooLarge)
        XCTAssertFalse(r.isAssembling)
    }

    func testMalformedFragments() {
        var r = Reassembler()
        if case .dropped = r.accept(Data([0x03, 0])) {} else { XCTFail() }
        if case .dropped = r.accept(Data()) {} else { XCTFail() }
        if case .dropped = r.accept(Data([0x03, 0, 1])) {} else { XCTFail("empty payload") }
    }
}

final class EnvelopeCryptoTests: XCTestCase {
    let key = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))

    func testSealLayoutNonceAndAad() throws {
        var phone = EnvelopeCodec(sessionKey: key)
        let plaintext = Data("{\"id\":1}".utf8)
        let envelope = try phone.seal(plaintext)

        XCTAssertEqual(envelope[0], 0x02)
        XCTAssertEqual(Array(envelope[1 ... 8]), [0, 0, 0, 0, 0, 0, 0, 1], "counter starts at 1, big endian")
        XCTAssertEqual(envelope.count, 9 + plaintext.count + 16)

        // Re-derive independently: nonce = direction(0x01) || 000000 || counter, AAD = type || counter
        let nonce = try AES.GCM.Nonce(data: Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        let box = try AES.GCM.SealedBox(
            nonce: nonce, ciphertext: envelope[9 ..< (envelope.count - 16)], tag: envelope.suffix(16)
        )
        let opened = try AES.GCM.open(box, using: key, authenticating: Data(envelope[0 ..< 9]))
        XCTAssertEqual(opened, plaintext)
    }

    func testFixedVector() throws {
        // key 00..1f, counter 1, plaintext {"id":1}: regression vector for the envelope format
        var phone = EnvelopeCodec(sessionKey: key)
        let envelope = try phone.seal(Data("{\"id\":1}".utf8))
        XCTAssertEqual(envelope.hexString, EnvelopeVectors.phoneCounter1)
    }

    func testRoundTripBothDirections() throws {
        var phone = EnvelopeCodec(sessionKey: key, sendDirection: .phoneToBridge)
        var bridge = EnvelopeCodec(sessionKey: key, sendDirection: .bridgeToPhone)
        for i in 1 ... 5 {
            let up = try phone.seal(Data("up\(i)".utf8))
            XCTAssertEqual(try bridge.open(up), Data("up\(i)".utf8))
            let down = try bridge.seal(Data("down\(i)".utf8))
            XCTAssertEqual(try phone.open(down), Data("down\(i)".utf8))
        }
        XCTAssertEqual(phone.lastSentCounter, 5)
    }

    func testReplayAndOldCountersAreRejected() throws {
        var phone = EnvelopeCodec(sessionKey: key)
        var bridge = EnvelopeCodec(sessionKey: key, sendDirection: .bridgeToPhone)
        let e1 = try bridge.seal(Data("1".utf8))
        let e2 = try bridge.seal(Data("2".utf8))
        XCTAssertEqual(try phone.open(e2), Data("2".utf8))
        XCTAssertThrowsError(try phone.open(e2)) { XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .replay) }
        XCTAssertThrowsError(try phone.open(e1), "counter lower than the last accepted one") {
            XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .replay)
        }
    }

    func testTamperingIsDetectedEverywhere() throws {
        var bridge = EnvelopeCodec(sessionKey: key, sendDirection: .bridgeToPhone)
        let good = try bridge.seal(Data("hello world".utf8))
        for index in [0, 1, 5, 8, 9, 12, good.count - 1] {
            var phone = EnvelopeCodec(sessionKey: key)
            var bad = good
            bad[index] ^= 0x01
            XCTAssertThrowsError(try phone.open(bad), "byte \(index)") { error in
                XCTAssertTrue(
                    [EnvelopeCodec.OpenError.authenticationFailed, .malformed, .replay]
                        .contains(error as? EnvelopeCodec.OpenError)
                )
            }
        }
        // A failed attempt must not burn the counter: the genuine message still opens.
        var phone = EnvelopeCodec(sessionKey: key)
        var tampered = good
        tampered[10] ^= 0x80
        XCTAssertThrowsError(try phone.open(tampered))
        XCTAssertEqual(try phone.open(good), Data("hello world".utf8))
    }

    func testOwnMessagesCannotBeReflected() throws {
        var phone = EnvelopeCodec(sessionKey: key)
        let mine = try phone.seal(Data("x".utf8))
        var phone2 = EnvelopeCodec(sessionKey: key)
        XCTAssertThrowsError(try phone2.open(mine), "direction byte is part of the nonce") {
            XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .authenticationFailed)
        }
    }

    func testWrongKeyAndMalformedEnvelopes() throws {
        var bridge = EnvelopeCodec(sessionKey: key, sendDirection: .bridgeToPhone)
        let env = try bridge.seal(Data("x".utf8))
        var other = EnvelopeCodec(sessionKey: SymmetricKey(data: Data(repeating: 9, count: 32)))
        XCTAssertThrowsError(try other.open(env))
        var phone = EnvelopeCodec(sessionKey: key)
        XCTAssertThrowsError(try phone.open(Data())) { XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .malformed) }
        XCTAssertThrowsError(try phone.open(Data([0x02] + [UInt8](repeating: 0, count: 20))))
        XCTAssertThrowsError(try phone.open(Data([0x01, 1, 2, 3]))) { XCTAssertEqual($0 as? EnvelopeCodec.OpenError, .malformed) }
    }

    func testHandshakeEnvelopes() throws {
        let env = try HandshakeMessage.encode(["t": "pairStart", "v": 1])
        XCTAssertEqual(env[0], 0x01)
        XCTAssertEqual(HandshakeMessage.decode(env)?["t"] as? String, "pairStart")
        XCTAssertNil(HandshakeMessage.decode(Data([0x01])))
        XCTAssertNil(HandshakeMessage.decode(Data([0x01, 0x7B])))
        XCTAssertNil(HandshakeMessage.decode(Data([0x02, 0x7B, 0x7D])))
    }
}

enum EnvelopeVectors {
    static let phoneCounter1 = "0200000000000000017cf70750284085ec2374f51ee39f90999e72fb436de5e56a"
}

final class PairingKDFTests: XCTestCase {
    // Reference values computed independently with Python's hmac/hashlib (RFC 5869 HKDF-SHA256).
    let z = Data(repeating: 0x42, count: 32)
    let nonceI = Data(0 ..< 16)
    let nonceB = Data((0 ..< 16).map { UInt8(0xA0 + $0) })

    private func bytes(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0).hexString } }

    func testLongTermKeyVector() {
        let ltk = BridgeKDF.longTermKey(rawSharedSecret: z, nonceI: nonceI, nonceB: nonceB)
        XCTAssertEqual(bytes(ltk), "a76e10bc7d628ec07e310ef8145dd9cd68f2bd501a2daacca875b4d84b8b3361")
    }

    func testSasAndMacVectors() {
        let ltk = BridgeKDF.longTermKey(rawSharedSecret: z, nonceI: nonceI, nonceB: nonceB)
        XCTAssertEqual(BridgeKDF.sas(ltk: ltk), "176987")
        XCTAssertEqual(
            BridgeKDF.confirmMacPhone(ltk: ltk).hexString,
            "a205a6a62895660232c2ac1d8c32690a7c37696be94fd8b712f85acda95a444c"
        )
        XCTAssertEqual(
            BridgeKDF.confirmMacBridge(ltk: ltk).hexString,
            "6dad2e2a5c397991b20fc8f8bef7eb7a5918cbbf3807779710bd1686d229e22a"
        )
        XCTAssertEqual(
            BridgeKDF.sessionMac(ltk: ltk, nonceI: nonceI, nonceB: nonceB).hexString,
            "be393507a485e4f29114efdb2715dcc7ecdcc72076bcbe0d2f38e85d0375c8a1"
        )
    }

    func testSessionKeyVector() {
        let ltk = BridgeKDF.longTermKey(rawSharedSecret: z, nonceI: nonceI, nonceB: nonceB)
        XCTAssertEqual(
            bytes(BridgeKDF.sessionKey(ltk: ltk, nonceI: nonceI, nonceB: nonceB)),
            "89aa7e32873bdc7373ce682a1d601e9c23ce23bd3dc4dd30a0e00d721e0d538b"
        )
    }

    func testSasIsAlwaysSixDigits() {
        for seed in 0 ..< 200 {
            let key = SymmetricKey(data: Data(repeating: UInt8(seed), count: 32))
            let sas = BridgeKDF.sas(ltk: key)
            XCTAssertEqual(sas.count, 6)
            XCTAssertNotNil(Int(sas))
        }
    }

    func testEcdhBothSidesAgree() throws {
        let a = P256.KeyAgreement.PrivateKey()
        let b = P256.KeyAgreement.PrivateKey()
        let sa = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let sb = try b.sharedSecretFromKeyAgreement(with: a.publicKey)
        let ltkA = BridgeKDF.longTermKey(sharedSecret: sa, nonceI: nonceI, nonceB: nonceB)
        let ltkB = BridgeKDF.longTermKey(sharedSecret: sb, nonceI: nonceI, nonceB: nonceB)
        XCTAssertEqual(bytes(ltkA), bytes(ltkB))
        XCTAssertEqual(BridgeKDF.sas(ltk: ltkA), BridgeKDF.sas(ltk: ltkB))
        // The shared-secret overload must equal the raw (x coordinate) overload.
        let raw = sa.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes(BridgeKDF.longTermKey(rawSharedSecret: raw, nonceI: nonceI, nonceB: nonceB)), bytes(ltkA))
        // X9.63 uncompressed public keys are 65 bytes starting with 0x04
        XCTAssertEqual(a.publicKey.x963Representation.count, 65)
        XCTAssertEqual(a.publicKey.x963Representation.first, 0x04)
    }

    func testMacComparisonIsExact() {
        XCTAssertTrue(BridgeKDF.verify(mac: Data([1, 2, 3]), expected: Data([1, 2, 3])))
        XCTAssertFalse(BridgeKDF.verify(mac: Data([1, 2, 3]), expected: Data([1, 2, 4])))
        XCTAssertFalse(BridgeKDF.verify(mac: Data([1, 2]), expected: Data([1, 2, 3])))
    }
}

enum CommitmentVectors {
    static let expected = "a9b7385b2baa03884fa1a72a6f39f3297d4c1adad7e1b4ca2e7530a9dbd779cb"
}
