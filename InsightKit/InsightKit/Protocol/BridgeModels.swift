import Foundation

// MARK: - JSON value

/// Minimal JSON tree so responses can be parsed without trusting their shape.
public enum BridgeValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BridgeValue])
    case object([String: BridgeValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([BridgeValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: BridgeValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> BridgeValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    /// Whole numbers only; never traps on huge/NaN values.
    public var intValue: Int? { doubleValue?.exactInt }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}

enum BridgeJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = BridgeDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from value: BridgeValue) throws -> T {
        do {
            let data = try encoder.encode(value)
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BridgeError.decoding(String(describing: type))
        }
    }

    static func toValue<T: Encodable>(_ value: T) throws -> BridgeValue {
        do {
            let data = try encoder.encode(value)
            return try decoder.decode(BridgeValue.self, from: data)
        } catch {
            throw BridgeError.encoding(String(describing: T.self))
        }
    }
}

// MARK: - Request arguments

public struct EmptyArgs: Codable, Equatable {
    public init() {}
}

public struct HelloArgs: Codable, Equatable {
    public let protocolVersion: Int
    public let app: String

    public init(protocolVersion: Int = BridgeProtocol.version, app: String) {
        self.protocolVersion = protocolVersion
        self.app = app
    }

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", app }
}

public struct DeliverBolusArgs: Codable, Equatable {
    public let amount: Double
    public let requestId: String
    public init(amount: Double, requestId: String) { self.amount = amount
        self.requestId = requestId }
}

public struct CancelBolusArgs: Codable, Equatable {
    public let bolusId: Int
    public init(bolusId: Int) { self.bolusId = bolusId }
}

public struct SetTBRArgs: Codable, Equatable {
    public let percent: Int
    public let duration: Int
    public let requestId: String
    public init(percent: Int, duration: Int, requestId: String) {
        self.percent = percent
        self.duration = duration
        self.requestId = requestId
    }
}

public struct RequestIdArgs: Codable, Equatable {
    public let requestId: String
    public init(requestId: String) { self.requestId = requestId }
}

public enum PumpOperatingModeCommand: String, Codable, Equatable {
    case started
    case stopped
}

public struct SetOperatingModeArgs: Codable, Equatable {
    public let mode: PumpOperatingModeCommand
    public let requestId: String
    public init(mode: PumpOperatingModeCommand, requestId: String) { self.mode = mode
        self.requestId = requestId }
}

public struct BasalSegment: Codable, Equatable {
    public let duration: Int
    public let rate: Double
    public init(duration: Int, rate: Double) { self.duration = duration
        self.rate = rate }
}

public struct SetBasalProfileArgs: Codable, Equatable {
    public let segments: [BasalSegment]
    public let requestId: String
    public init(segments: [BasalSegment], requestId: String) { self.segments = segments
        self.requestId = requestId }
}

public struct SetDateTimeArgs: Codable, Equatable {
    public let utc: String
    public let tzOffsetMinutes: Int
    public init(utc: Date, tzOffsetMinutes: Int) {
        self.utc = BridgeDate.format(utc)
        self.tzOffsetMinutes = tzOffsetMinutes
    }
}

public struct ReadHistoryArgs: Codable, Equatable {
    public let sinceSequence: Int?
    public let max: Int

    public init(sinceSequence: Int?, max: Int = BridgeProtocol.historyPageSize) {
        self.sinceSequence = sinceSequence
        self.max = Swift.min(max, BridgeProtocol.historyPageSize)
    }

    enum CodingKeys: String, CodingKey { case sinceSequence, max }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `null` must be sent explicitly: the contract says "int | null"
        if let sinceSequence { try c.encode(sinceSequence, forKey: .sinceSequence) }
        else { try c.encodeNil(forKey: .sinceSequence) }
        try c.encode(max, forKey: .max)
    }
}

public struct AlertRefArgs: Codable, Equatable {
    public let alertId: Int
    public let alertType: String
    public init(alertId: Int, alertType: String) { self.alertId = alertId
        self.alertType = alertType }
}

// MARK: - Results

public struct EmptyResult: Codable, Equatable {
    public init() {}
}

public struct HelloResult: Codable, Equatable {
    public let protocolVersion: Int?
    public let bridgeVersion: String?
    public let pumpPaired: Bool

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", bridgeVersion, pumpPaired }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try? c.decodeIfPresent(Int.self, forKey: .protocolVersion)
        bridgeVersion = try? c.decodeIfPresent(String.self, forKey: .bridgeVersion)
        pumpPaired = (try? c.decode(Bool.self, forKey: .pumpPaired)) ?? false
    }

    public init(protocolVersion: Int?, bridgeVersion: String?, pumpPaired: Bool) {
        self.protocolVersion = protocolVersion
        self.bridgeVersion = bridgeVersion
        self.pumpPaired = pumpPaired
    }
}

public struct DeliverBolusResult: Codable, Equatable {
    public let bolusId: Int
    public let amount: Double
}

public struct CancelBolusResult: Codable, Equatable {
    public let delivered: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try? c.decodeIfPresent(Double.self, forKey: .delivered)
    }

    enum CodingKeys: String, CodingKey { case delivered }
    public init(delivered: Double?) { self.delivered = delivered }
}

public struct SetTBRResult: Codable, Equatable {
    public let percent: Int
    public let duration: Int
}

public struct OperatingModeResult: Codable, Equatable {
    public let mode: String
}

public struct SetBasalProfileResult: Codable, Equatable {
    public let activeProfile: Int?
}

public enum RequestOutcomeState: String, Codable, Equatable {
    case unknown
    case inProgress
    case succeeded
    case failed
    case uncertain

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestOutcomeState(rawValue: raw) ?? .unknown
    }
}

/// `getRequestOutcome` (v2): the bridge's own record of what happened to a request.
public struct RequestOutcomeResult: Decodable, Equatable {
    public let state: RequestOutcomeState
    public let result: BridgeValue?
    public let error: BridgeRemoteError?
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey { case state, result, error, completedAt }

    public init(
        state: RequestOutcomeState,
        result: BridgeValue? = nil,
        error: BridgeRemoteError? = nil,
        completedAt: Date? = nil
    ) {
        self.state = state
        self.result = result
        self.error = error
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unreadable state is "unknown": the evidence path decides, never a guess.
        state = (try? c.decode(RequestOutcomeState.self, forKey: .state)) ?? .unknown
        result = try? c.decodeIfPresent(BridgeValue.self, forKey: .result)
        error = try? c.decodeIfPresent(BridgeRemoteError.self, forKey: .error)
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

public struct PumpPairingStatusResult: Codable, Equatable {
    public let paired: Bool
    public let serial: String?
    public let bridgeBluetoothOn: Bool?
}

// MARK: - Status

public enum PumpLinkState: String, Codable, Equatable {
    case connected
    case connecting
    case disconnected
    case notPaired
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PumpLinkState(rawValue: raw) ?? .unknown
    }
}

public enum PumpOperatingMode: String, Codable, Equatable {
    case started
    case stopped
    case paused
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PumpOperatingMode(rawValue: raw) ?? .unknown
    }

    public var isDelivering: Bool { self == .started }
}

public struct BridgeStatus: Codable, Equatable {
    public struct Battery: Codable, Equatable {
        public let percent: Double?
    }

    public struct Reservoir: Codable, Equatable {
        public let units: Double?
        public let cartridgeType: String?
    }

    public struct Basal: Codable, Equatable {
        public let activeProfile: Int?
        public let rate: Double?
    }

    public struct TBR: Codable, Equatable {
        public let percent: Int
        public let duration: Int
        public let remaining: Int?
        public let start: Date?
    }

    public struct ActiveBolus: Codable, Equatable {
        public let bolusId: Int
        public let type: String?
        public let amount: Double
        public let remaining: Double
    }

    public struct PumpTime: Codable, Equatable {
        public let utc: Date?
        public let pumpLocal: String?
        public let driftSeconds: Double?
    }

    public struct Limits: Codable, Equatable {
        public let maxBolus: Double?
        public let maxBasal: Double?
        public let bolusStep: Double?
        public let basalStep: Double?
        public let minBasal: Double?
    }

    public var timestamp: Date?
    public let pumpLink: PumpLinkState
    public let serial: String?
    public let firmware: String?
    public let operatingMode: PumpOperatingMode
    public let battery: Battery?
    public let reservoir: Reservoir?
    public let basal: Basal?
    public let tbr: TBR?
    public let boluses: [ActiveBolus]
    public let pumpTime: PumpTime?
    public let limits: Limits?
    public let activeAlert: BridgeAlert?
    public let lastHistorySequence: Int?
    /// The `tbr` field was present but could not be parsed: unknown, which is not the same as "no TBR".
    public var tbrIsUnreadable = false
    /// The `boluses` field was present but could not be parsed: unknown, which is not the same as "no bolus".
    public var bolusesAreUnreadable = false

    enum CodingKeys: String, CodingKey {
        case timestamp
        case pumpLink
        case serial
        case firmware
        case operatingMode
        case battery
        case reservoir
        case basal
        case tbr
        case boluses
        case pumpTime
        case limits
        case activeAlert
        case lastHistorySequence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        pumpLink = (try? c.decodeIfPresent(PumpLinkState.self, forKey: .pumpLink)) ?? .unknown
        serial = try? c.decodeIfPresent(String.self, forKey: .serial)
        firmware = try? c.decodeIfPresent(String.self, forKey: .firmware)
        operatingMode = (try? c.decodeIfPresent(PumpOperatingMode.self, forKey: .operatingMode)) ?? .unknown
        battery = try? c.decodeIfPresent(Battery.self, forKey: .battery)
        reservoir = try? c.decodeIfPresent(Reservoir.self, forKey: .reservoir)
        basal = try? c.decodeIfPresent(Basal.self, forKey: .basal)
        var decodedTbr: TBR?
        if c.contains(.tbr), (try? c.decodeNil(forKey: .tbr)) != true {
            do { decodedTbr = try c.decode(TBR.self, forKey: .tbr) } catch { tbrIsUnreadable = true }
        }
        tbr = decodedTbr
        var decodedBoluses = [ActiveBolus]()
        if c.contains(.boluses), (try? c.decodeNil(forKey: .boluses)) != true {
            do { decodedBoluses = try c.decode([ActiveBolus].self, forKey: .boluses) } catch { bolusesAreUnreadable = true }
        }
        boluses = decodedBoluses
        pumpTime = try? c.decodeIfPresent(PumpTime.self, forKey: .pumpTime)
        limits = try? c.decodeIfPresent(Limits.self, forKey: .limits)
        activeAlert = try? c.decodeIfPresent(BridgeAlert.self, forKey: .activeAlert)
        lastHistorySequence = try? c.decodeIfPresent(Int.self, forKey: .lastHistorySequence)
    }

    public init(
        timestamp: Date?, pumpLink: PumpLinkState = .connected, serial: String? = nil, firmware: String? = nil,
        operatingMode: PumpOperatingMode = .started, battery: Battery? = nil, reservoir: Reservoir? = nil,
        basal: Basal? = nil, tbr: TBR? = nil, boluses: [ActiveBolus] = [], pumpTime: PumpTime? = nil,
        limits: Limits? = nil, activeAlert: BridgeAlert? = nil, lastHistorySequence: Int? = nil,
        tbrIsUnreadable: Bool = false, bolusesAreUnreadable: Bool = false
    ) {
        self.tbrIsUnreadable = tbrIsUnreadable
        self.bolusesAreUnreadable = bolusesAreUnreadable
        self.timestamp = timestamp
        self.pumpLink = pumpLink
        self.serial = serial
        self.firmware = firmware
        self.operatingMode = operatingMode
        self.battery = battery
        self.reservoir = reservoir
        self.basal = basal
        self.tbr = tbr
        self.boluses = boluses
        self.pumpTime = pumpTime
        self.limits = limits
        self.activeAlert = activeAlert
        self.lastHistorySequence = lastHistorySequence
    }
}

extension BridgeStatus {
    /// A read time further in the future than this is not believed.
    static let maxClockSkew: TimeInterval = 2 * 60

    /// A status stamped in the future (broken clock on the bridge) must neither win the "newest status" race
    /// nor look fresh: its timestamp is dropped (treated as unknown).
    func sanitized(now: Date) -> BridgeStatus {
        guard let t = timestamp, t > now.addingTimeInterval(Self.maxClockSkew) else { return self }
        var copy = self
        copy.timestamp = nil
        return copy
    }
}

// MARK: - Alerts

public enum BridgeAlertCategory: String, Codable, Equatable {
    case reminder
    case maintenance
    case warning
    case error
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BridgeAlertCategory(rawValue: raw) ?? .unknown
    }
}

public struct BridgeAlert: Codable, Equatable {
    public let alertId: Int
    public let alertType: String
    public let category: BridgeAlertCategory
    public let status: String?
    public let tbrPercent: Int?
    public let remainingInsulin: Double?

    enum CodingKeys: String, CodingKey { case alertId, alertType, category, status, tbrPercent, remainingInsulin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alertId = try c.decode(Int.self, forKey: .alertId)
        alertType = try c.decode(String.self, forKey: .alertType)
        category = (try? c.decodeIfPresent(BridgeAlertCategory.self, forKey: .category)) ?? .unknown
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        tbrPercent = try? c.decodeIfPresent(Int.self, forKey: .tbrPercent)
        remainingInsulin = try? c.decodeIfPresent(Double.self, forKey: .remainingInsulin)
    }

    public init(
        alertId: Int,
        alertType: String,
        category: BridgeAlertCategory,
        status: String? = "active",
        tbrPercent: Int? = nil,
        remainingInsulin: Double? = nil
    )
    {
        self.alertId = alertId
        self.alertType = alertType
        self.category = category
        self.status = status
        self.tbrPercent = tbrPercent
        self.remainingInsulin = remainingInsulin
    }

    public var isSnoozed: Bool { status == "snoozed" }
}

// MARK: - History

public enum HistoryEventKind: String, Equatable {
    case bolusProgrammed
    case bolusDelivered
    case tbrStart
    case tbrEnd
    case basalRateChanged
    case operatingModeChanged
    case cartridgeInserted
    case cartridgeRemoved
    case tubeFilled
    case cannulaFilled
    case totalDailyDose
    case alert
    case dateTimeChanged
    case other
}

public struct HistoryEvent: Codable, Equatable {
    public let seq: Int
    public let time: Date
    public let typeName: String
    public let data: BridgeValue

    public var kind: HistoryEventKind { HistoryEventKind(rawValue: typeName) ?? .other }

    enum CodingKeys: String, CodingKey { case seq, time, type, data }

    public init(seq: Int, time: Date, type: String, data: BridgeValue) {
        self.seq = seq
        self.time = time
        typeName = type
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        time = try c.decode(Date.self, forKey: .time)
        typeName = try c.decode(String.self, forKey: .type)
        data = (try? c.decodeIfPresent(BridgeValue.self, forKey: .data)) ?? .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(BridgeDate.format(time), forKey: .time)
        try c.encode(typeName, forKey: .type)
        try c.encode(data, forKey: .data)
    }

    func number(_ key: String) -> Double? { data[key]?.doubleValue }
    func int(_ key: String) -> Int? { data[key]?.intValue }
    func string(_ key: String) -> String? { data[key]?.stringValue }
    func date(_ key: String) -> Date? { data[key]?.stringValue.flatMap(BridgeDate.parse) }
}

/// What could still be read of a history event that could not be decoded as a whole.
public struct UnreadableHistoryEvent: Equatable {
    public let seq: Int?
    public let typeName: String?
    public let time: Date?
    /// For bolus events: the programmed amount if it was readable.
    public let programmed: Double?

    public var isBolus: Bool { typeName == "bolusDelivered" || typeName == "bolusProgrammed" }

    public init(seq: Int?, typeName: String?, time: Date?, programmed: Double?) {
        self.seq = seq
        self.typeName = typeName
        self.time = time
        self.programmed = programmed
    }
}

/// A history page. A malformed event never fails the page, but it is remembered (`unreadable`) so the caller
/// does not move past it and can treat an unreadable bolus conservatively.
public struct HistoryResult: Decodable, Equatable {
    public let events: [HistoryEvent]
    public let unreadable: [UnreadableHistoryEvent]
    public let lastSequence: Int
    public let more: Bool

    public var skippedEvents: Int { unreadable.count }

    enum CodingKeys: String, CodingKey { case events, lastSequence, more }

    private struct Lossy: Decodable {
        let event: HistoryEvent?
        let unreadable: UnreadableHistoryEvent?

        init(from decoder: Decoder) throws {
            if let event = try? HistoryEvent(from: decoder) {
                self.event = event
                unreadable = nil
                return
            }
            event = nil
            let raw = try? BridgeValue(from: decoder)
            let data = raw?["data"]
            unreadable = UnreadableHistoryEvent(
                seq: raw?["seq"]?.intValue,
                typeName: raw?["type"]?.stringValue,
                time: raw?["time"]?.stringValue.flatMap(BridgeDate.parse),
                programmed: (data?["programmed"] ?? data?["amount"])?.doubleValue
            )
        }
    }

    public init(events: [HistoryEvent], lastSequence: Int, more: Bool, unreadable: [UnreadableHistoryEvent] = []) {
        self.events = events
        self.unreadable = unreadable
        self.lastSequence = lastSequence
        self.more = more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try c.decode([Lossy].self, forKey: .events)
        events = lossy.compactMap(\.event)
        unreadable = lossy.compactMap(\.unreadable)
        lastSequence = try c.decode(Int.self, forKey: .lastSequence)
        more = (try? c.decodeIfPresent(Bool.self, forKey: .more)) ?? false
    }
}

// MARK: - Events (unsolicited)

public struct BolusProgress: Codable, Equatable {
    public let bolusId: Int
    public let delivered: Double
    public let remaining: Double
}

public enum BridgeEvent: Equatable {
    case status(BridgeStatus)
    case alert(BridgeAlert)
    case bolusProgress(BolusProgress)
    case pumpLink(PumpLinkState)
    case unknown(String)
}
