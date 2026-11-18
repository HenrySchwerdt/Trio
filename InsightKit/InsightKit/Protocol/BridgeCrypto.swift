import CryptoKit
import Foundation

/// Direction byte used in the GCM nonce.
public enum BridgeDirection: UInt8 {
    case phoneToBridge = 0x01
    case bridgeToPhone = 0x02

    var opposite: BridgeDirection { self == .phoneToBridge ? .bridgeToPhone : .phoneToBridge }
}

public enum EnvelopeType: UInt8 {
    case plaintextHandshake = 0x01
    case encrypted = 0x02
}

/// §3 envelope encoding. Sending and receiving counters are tracked per session.
public struct EnvelopeCodec {
    public static let tagSize = 16
    public static let headerSize = 9 // type + counter

    private let key: SymmetricKey
    private let sendDirection: BridgeDirection
    private var sendCounter: UInt64 = 0
    private var lastReceivedCounter: UInt64 = 0

    public enum OpenError: Error, Equatable {
        case malformed
        case replay
        case authenticationFailed
    }

    /// For interoperability tests: start counting from a given point (counters normally start at 1).
    init(sessionKey: SymmetricKey, sendDirection: BridgeDirection, sendCounter: UInt64, lastReceivedCounter: UInt64) {
        key = sessionKey
        self.sendDirection = sendDirection
        self.sendCounter = sendCounter
        self.lastReceivedCounter = lastReceivedCounter
    }

    public init(sessionKey: SymmetricKey, sendDirection: BridgeDirection = .phoneToBridge) {
        key = sessionKey
        self.sendDirection = sendDirection
    }

    public var lastSentCounter: UInt64 { sendCounter }

    static func nonce(direction: BridgeDirection, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data([direction.rawValue, 0, 0, 0])
        bytes.append(counter.bigEndianBytes)
        return try AES.GCM.Nonce(data: bytes)
    }

    /// Encrypts `plaintext` and returns the complete envelope bytes.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let next = sendCounter &+ 1
        guard next != 0 else { throw BridgeError.protocolViolation("counter exhausted") }
        var header = Data([EnvelopeType.encrypted.rawValue])
        header.append(next.bigEndianBytes)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: Self.nonce(direction: sendDirection, counter: next),
            authenticating: header
        )
        sendCounter = next
        return header + box.ciphertext + box.tag
    }

    /// Verifies and decrypts an incoming envelope. Replays and tampering are errors.
    public mutating func open(_ envelope: Data) throws -> Data {
        let bytes = [UInt8](envelope)
        guard bytes.count >= Self.headerSize + Self.tagSize, bytes[0] == EnvelopeType.encrypted.rawValue else {
            throw OpenError.malformed
        }
        let counter = bytes[1 ... 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter > lastReceivedCounter else { throw OpenError.replay }

        let header = Data(bytes[0 ..< Self.headerSize])
        let ciphertext = Data(bytes[Self.headerSize ..< (bytes.count - Self.tagSize)])
        let tag = Data(bytes[(bytes.count - Self.tagSize)...])
        do {
            let nonce = try Self.nonce(direction: sendDirection.opposite, counter: counter)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: key, authenticating: header)
            lastReceivedCounter = counter // only advanced after a valid tag
            return plain
        } catch {
            throw OpenError.authenticationFailed
        }
    }

    // MARK: plaintext handshake envelope

    public static func handshakeEnvelope(json: Data) -> Data {
        Data([EnvelopeType.plaintextHandshake.rawValue]) + json
    }

    /// Returns the JSON body of a plaintext handshake envelope, nil if it is not one.
    public static func handshakeBody(of envelope: Data) -> Data? {
        guard envelope.first == EnvelopeType.plaintextHandshake.rawValue, envelope.count > 1 else { return nil }
        return envelope.dropFirst()
    }

    public static func isEncrypted(_ envelope: Data) -> Bool {
        envelope.first == EnvelopeType.encrypted.rawValue
    }
}

extension UInt64 {
    var bigEndianBytes: Data {
        var v = bigEndian
        return Data(bytes: &v, count: 8)
    }
}

/// Key derivation, SAS and MACs of §4. All pure functions so they can be tested with fixed vectors.
public enum BridgeKDF {
    static let ltkInfo = Data("InsightBridge LTK v1".utf8)
    static let skInfo = Data("InsightBridge SK v1".utf8)

    /// LTK = HKDF-SHA256(ikm = ECDH x-coordinate, salt = nonceI || nonceB, info = "InsightBridge LTK v1", 32)
    public static func longTermKey(sharedSecret: SharedSecret, nonceI: Data, nonceB: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: nonceI + nonceB, sharedInfo: ltkInfo, outputByteCount: 32
        )
    }

    /// Same derivation from a raw ECDH result (used by test vectors).
    public static func longTermKey(rawSharedSecret z: Data, nonceI: Data, nonceB: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: z), salt: nonceI + nonceB, info: ltkInfo, outputByteCount: 32
        )
    }

    static let commitPrefix = Data("InsightBridge commit v2".utf8)

    /// v2 pairing commitment: SHA-256("InsightBridge commit v2" || pubI (raw 65 B X9.63) || nonceI)
    public static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: commitPrefix + publicKey + nonce))
    }

    /// SK = HKDF-SHA256(ikm = LTK, salt = nonceI || nonceB, info = "InsightBridge SK v1", 32)
    public static func sessionKey(ltk: SymmetricKey, nonceI: Data, nonceB: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ltk, salt: nonceI + nonceB, info: skInfo, outputByteCount: 32)
    }

    static func hmac(_ ltk: SymmetricKey, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: ltk))
    }

    /// 6-digit SAS = uint32BE(HMAC-SHA256(LTK, "SAS")[0..3]) mod 1_000_000
    public static func sas(ltk: SymmetricKey) -> String {
        let mac = [UInt8](hmac(ltk, Data("SAS".utf8)))
        let value = UInt32(mac[0]) << 24 | UInt32(mac[1]) << 16 | UInt32(mac[2]) << 8 | UInt32(mac[3])
        return String(format: "%06u", value % 1_000_000)
    }

    public static func confirmMacPhone(ltk: SymmetricKey) -> Data { hmac(ltk, Data("confirm-i".utf8)) }
    public static func confirmMacBridge(ltk: SymmetricKey) -> Data { hmac(ltk, Data("confirm-b".utf8)) }

    /// HMAC-SHA256(LTK, "session" || nonceI || nonceB)
    public static func sessionMac(ltk: SymmetricKey, nonceI: Data, nonceB: Data) -> Data {
        hmac(ltk, Data("session".utf8) + nonceI + nonceB)
    }

    /// Constant-time MAC comparison.
    public static func verify(mac: Data, expected: Data) -> Bool {
        guard mac.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(mac, expected) { diff |= a ^ b }
        return diff == 0
    }
}

// MARK: - Handshake messages (plaintext JSON, §4)

enum HandshakeMessage {
    /// v2: only a commitment goes out first; the values follow in `pairReveal` once the bridge has answered.
    static func pairStart(commit: Data) -> [String: Any] {
        ["t": "pairStart", "v": BridgeProtocol.version, "commit": commit.base64EncodedString()]
    }

    static func pairReveal(publicKey: Data, nonce: Data) -> [String: Any] {
        ["t": "pairReveal", "pub": publicKey.base64EncodedString(), "nonce": nonce.base64EncodedString()]
    }

    static func pairConfirm(mac: Data) -> [String: Any] {
        ["t": "pairConfirm", "mac": mac.base64EncodedString()]
    }

    static func pairReject(reason: String) -> [String: Any] {
        ["t": "pairReject", "reason": reason]
    }

    static func sessionStart(clientId: String, nonce: Data) -> [String: Any] {
        ["t": "sessionStart", "v": BridgeProtocol.version, "clientId": clientId, "nonce": nonce.base64EncodedString()]
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { throw BridgeError.encoding("handshake") }
        return EnvelopeCodec.handshakeEnvelope(json: data)
    }

    static func decode(_ envelope: Data) -> [String: Any]? {
        guard let body = EnvelopeCodec.handshakeBody(of: envelope),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object
    }

    static func data(_ object: [String: Any], _ key: String, count: Int? = nil) -> Data? {
        guard let s = object[key] as? String, let d = Data(base64Encoded: s) else { return nil }
        if let count, d.count != count { return nil }
        return d
    }
}
