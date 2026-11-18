import Foundation

/// §2 framing: every GATT write/notification carries one fragment
/// `flags(1) | messageSeq(uint16 BE) | payload`.
public enum Fragmenter {
    public static let headerSize = 3
    public static let flagFirst: UInt8 = 0x01
    public static let flagLast: UInt8 = 0x02

    /// Splits a message into fragments no longer than `maxFragmentSize` bytes (header included).
    /// Returns nil if the message is empty/too large or the fragment size cannot hold a payload byte.
    public static func fragments(of message: Data, messageSeq: UInt16, maxFragmentSize: Int) -> [Data]? {
        guard !message.isEmpty, message.count <= BridgeProtocol.maxMessageSize else { return nil }
        let payloadSize = maxFragmentSize - headerSize
        guard payloadSize > 0 else { return nil }

        var result = [Data]()
        var offset = 0
        let bytes = [UInt8](message)
        while offset < bytes.count {
            let end = min(offset + payloadSize, bytes.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= flagFirst }
            if end == bytes.count { flags |= flagLast }
            var fragment = Data([flags, UInt8(messageSeq >> 8), UInt8(messageSeq & 0xFF)])
            fragment.append(contentsOf: bytes[offset ..< end])
            result.append(fragment)
            offset = end
        }
        return result
    }
}

public struct Reassembler {
    public enum Outcome: Equatable {
        case complete(Data)
        case incomplete
        case dropped(String)
        /// The message exceeded `maxMessageSize`; the caller may want to tell the peer.
        case tooLarge
    }

    private var currentSeq: UInt16?
    private var buffer = Data()
    private var startedAt: Date?
    private let timeout: TimeInterval
    private let maxSize: Int

    public init(timeout: TimeInterval = BridgeProtocol.reassemblyTimeout, maxSize: Int = BridgeProtocol.maxMessageSize) {
        self.timeout = timeout
        self.maxSize = maxSize
    }

    public var isAssembling: Bool { currentSeq != nil }

    public mutating func reset() {
        currentSeq = nil
        buffer = Data()
        startedAt = nil
    }

    /// Drops a stale partial message. Returns true when something was dropped.
    @discardableResult public mutating func expire(now: Date) -> Bool {
        guard let startedAt, now.timeIntervalSince(startedAt) > timeout else { return false }
        reset()
        return true
    }

    public mutating func accept(_ fragment: Data, now: Date = Date()) -> Outcome {
        expire(now: now)

        let bytes = [UInt8](fragment)
        guard bytes.count >= Fragmenter.headerSize else { return .dropped("short fragment") }
        let flags = bytes[0]
        let seq = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        let payload = bytes[Fragmenter.headerSize...]
        let isFirst = flags & Fragmenter.flagFirst != 0
        let isLast = flags & Fragmenter.flagLast != 0

        if isFirst {
            // A FIRST fragment always starts over (this also covers "different messageSeq").
            reset()
            currentSeq = seq
            startedAt = now
        } else {
            guard let currentSeq else { return .dropped("continuation without start") }
            guard currentSeq == seq else {
                reset()
                return .dropped("sequence mismatch")
            }
        }

        if buffer.count + payload.count > maxSize {
            reset()
            return .tooLarge
        }
        buffer.append(contentsOf: payload)

        guard isLast else { return .incomplete }
        let message = buffer
        reset()
        return message.isEmpty ? .dropped("empty message") : .complete(message)
    }
}
