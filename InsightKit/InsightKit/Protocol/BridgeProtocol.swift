import CoreBluetooth
import Foundation

/// Constants of the Insight Bridge protocol v1 (see PROTOCOL.md next to this project).
public enum BridgeProtocol {
    public static let version = 2

    public static let serviceUUID = CBUUID(string: "2462D0E9-9BA1-4434-8DFE-75D844AC9945")
    /// iPhone -> bridge, write with response
    public static let rxCharacteristicUUID = CBUUID(string: "6FAFD9DD-5BCE-4A1D-B262-A61B50AE7842")
    /// bridge -> iPhone, notify
    public static let txCharacteristicUUID = CBUUID(string: "7EDC9323-9BFA-4A7E-AFBB-92DEE0F0B917")

    public static let advertisedNamePrefix = "InsightBridge-"

    /// Display name of a discovered bridge: "InsightBridge-" + the ASCII service data (last 4 hex of the bridge id)
    /// when present, else "InsightBridge (<phone name>)". Never used for filtering.
    public static func displayName(serviceData: [CBUUID: Data]?, peripheralName: String?) -> String {
        if let data = serviceData?[serviceUUID], !data.isEmpty,
           let id = String(data: data.prefix(8), encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty { return advertisedNamePrefix + id.uppercased() }
        if let name = peripheralName, !name.isEmpty { return "InsightBridge (\(name))" }
        return advertisedNamePrefix + "????"
    }

    /// The bridge id suffix from the advertisement's service data (uppercase ASCII), nil if absent.
    public static func advertisedId(serviceData: [CBUUID: Data]?) -> String? {
        guard let data = serviceData?[serviceUUID], !data.isEmpty,
              let id = String(data: data.prefix(8), encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id.uppercased()
    }

    /// True unless the advertisement names a different bridge than `bridgeId` (no data: cannot tell, so maybe).
    public static func advertisement(_ advertisedId: String?, couldBe bridgeId: String?) -> Bool {
        guard let advertisedId, let bridgeId, !bridgeId.isEmpty else { return true }
        return bridgeId.uppercased().hasSuffix(advertisedId)
    }

    /// Maximum reassembled message size.
    public static let maxMessageSize = 16 * 1024
    /// A partial message is discarded after this long without its LAST fragment.
    public static let reassemblyTimeout: TimeInterval = 5

    // Timeouts (iOS side)
    public static let statusTimeout: TimeInterval = 30
    public static let dosingTimeout: TimeInterval = 45
    /// How long a queued command waits for the link/session to come up before it is failed
    /// (nothing has been sent at that point, so the failure is certain).
    public static let connectWait: TimeInterval = 20
    public static let pairingResponseTimeout: TimeInterval = 15
    /// §1a: a candidate must complete the session handshake within this time.
    public static let handshakeTimeout: TimeInterval = 10
    /// §1a: how long a candidate that is not the paired bridge stays on the ignore list.
    public static let ignoreDuration: TimeInterval = 10 * 60
    /// A device that never completed the handshake (silent) is skipped for this long.
    public static let silentIgnoreDuration: TimeInterval = 2 * 60
    /// §1a: liveness ping while a session is up, and how long the answer may take.
    public static let pingInterval: TimeInterval = 60
    public static let pingTimeout: TimeInterval = 10
    public static let pairingConfirmTimeout: TimeInterval = 130
    /// Status older than this is stale.
    public static let staleStatusAge: TimeInterval = 15 * 60
    /// A rejected session is only believed after it happened twice, this far apart.
    public static let sessionRejectRetryDelay: TimeInterval = 30
    /// Back-off between `getRequestOutcome` queries while the bridge says `inProgress`.
    public static let outcomeBackoff: [TimeInterval] = [5, 10, 20, 40, 60]
    /// A status must have been read this long after a command before it can show that the command did not run.
    public static let notDeliveredSettleTime: TimeInterval = 60

    /// 50 events keep a page well below the 16 KiB message limit.
    public static let historyPageSize = 50
}

/// Operations of §5.1
public enum BridgeOp: String, CaseIterable {
    case hello
    case getStatus
    case deliverBolus
    case cancelBolus
    case setTBR
    case cancelTBR
    case setOperatingMode
    case setBasalProfile
    case setDateTime
    case readHistory
    case confirmAlert
    case snoozeAlert
    case getRequestOutcome
    case pumpPairingStatus
    case ping

    /// Ops that change what the pump delivers (or may). A timeout on those is "uncertain".
    public var isDosing: Bool {
        switch self {
        case .cancelBolus,
             .cancelTBR,
             .deliverBolus,
             .setBasalProfile,
             .setOperatingMode,
             .setTBR:
            return true
        default:
            return false
        }
    }

    public var timeout: TimeInterval {
        if self == .ping { return BridgeProtocol.pingTimeout }
        return isDosing ? BridgeProtocol.dosingTimeout : BridgeProtocol.statusTimeout
    }
}

// MARK: - Errors

public enum BridgeErrorCode: String, Codable, Equatable {
    case notPaired
    case pumpUnreachable
    case pumpSuspended
    case pumpBusy
    case invalidArgs
    case limitExceeded
    case verifyFailed
    case alertActive
    case busy
    case tooLarge
    case unsupportedProtocol
    case `internal`
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BridgeErrorCode(rawValue: raw) ?? .unknown
    }
}

public struct BridgeRemoteError: Codable, Equatable {
    public let code: BridgeErrorCode
    public let message: String
    public let uncertain: Bool

    public init(code: BridgeErrorCode, message: String, uncertain: Bool) {
        self.code = code
        self.message = message
        self.uncertain = uncertain
    }

    enum CodingKeys: String, CodingKey { case code, message, uncertain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decode(BridgeErrorCode.self, forKey: .code)) ?? .unknown
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        uncertain = (try? c.decode(Bool.self, forKey: .uncertain)) ?? false
    }
}

/// Everything that can go wrong talking to the bridge. `isUncertainOutcome` is the only
/// property dosing code may use to decide whether a command might have been executed.
public enum BridgeError: Error, Equatable {
    /// The link/session could not be brought up before the command was sent. Nothing was sent.
    case notConnected
    /// The link dropped after the command may have been sent.
    case linkLost
    /// No response in time after the command was sent.
    case timeout
    case remote(BridgeRemoteError)
    case sessionRejected(String)
    case pairingRejected(String)
    case unsupportedProtocol
    case protocolViolation(String)
    case decoding(String)
    case encoding(String)
    case missingCredentials
    case macMismatch
    case bluetoothUnavailable(String)

    /// Whether the command might have been executed by the pump although we got no (valid) success.
    public var isUncertainOutcome: Bool {
        switch self {
        case .linkLost,
             .timeout:
            return true
        case let .remote(error):
            return error.uncertain
        default:
            return false
        }
    }

    public var isTimeoutLike: Bool {
        switch self {
        case .linkLost,
             .timeout: return true
        default: return false
        }
    }
}

extension BridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return LocalizedString("Not connected to the InsightBridge app.", comment: "Bridge error")
        case .linkLost:
            return LocalizedString("The connection to the InsightBridge app was lost.", comment: "Bridge error")
        case .timeout:
            return LocalizedString("The InsightBridge app did not answer in time.", comment: "Bridge error")
        case let .remote(e):
            return e.code.localizedDescription(message: e.message)
        case .sessionRejected:
            return LocalizedString(
                "The InsightBridge app does not know this iPhone. Pair the bridge again.",
                comment: "Bridge error"
            )
        case let .pairingRejected(reason):
            switch reason {
            case "notInPairingMode":
                return LocalizedString(
                    "The bridge is not in pairing mode. Tap \"Pair with iPhone\" in the InsightBridge app and try again.",
                    comment: "Bridge error"
                )
            case "commitMismatch":
                return LocalizedString(
                    "The bridge rejected the pairing data. Something may be interfering; try again close to the bridge.",
                    comment: "Bridge error"
                )
            default:
                return LocalizedString("Pairing was cancelled.", comment: "Bridge error")
            }
        case .unsupportedProtocol:
            return LocalizedString(
                "The InsightBridge app uses an incompatible protocol version. Update both apps.",
                comment: "Bridge error"
            )
        case let .protocolViolation(detail):
            return String(
                format: LocalizedString("Invalid data from the InsightBridge app (%@).", comment: "Bridge error"),
                detail
            )
        case let .decoding(detail):
            return String(
                format: LocalizedString("Could not read the answer of the InsightBridge app (%@).", comment: "Bridge error"),
                detail
            )
        case let .encoding(detail):
            return String(format: LocalizedString("Could not build the request (%@).", comment: "Bridge error"), detail)
        case .missingCredentials:
            return LocalizedString("This iPhone is not paired with an InsightBridge app.", comment: "Bridge error")
        case .macMismatch:
            return LocalizedString("The bridge could not be verified. Pair the bridge again.", comment: "Bridge error")
        case let .bluetoothUnavailable(reason):
            return reason
        }
    }
}

extension BridgeErrorCode {
    func localizedDescription(message: String) -> String {
        switch self {
        case .notPaired:
            return LocalizedString(
                "The InsightBridge app has no Insight pump paired. Pair the pump in the bridge app first.",
                comment: "Bridge error code"
            )
        case .pumpUnreachable:
            return LocalizedString("The bridge cannot reach the pump.", comment: "Bridge error code")
        case .pumpSuspended:
            return LocalizedString("The pump is suspended.", comment: "Bridge error code")
        case .pumpBusy:
            return LocalizedString("The pump is busy.", comment: "Bridge error code")
        case .alertActive:
            return LocalizedString("The pump shows an alert that must be confirmed first.", comment: "Bridge error code")
        case .busy:
            return LocalizedString("The bridge is in use by another phone.", comment: "Bridge error code")
        case .limitExceeded:
            return LocalizedString("The requested value exceeds a pump limit.", comment: "Bridge error code")
        case .verifyFailed:
            return LocalizedString("The pump did not confirm the change.", comment: "Bridge error code")
        case .internal,
             .invalidArgs,
             .tooLarge,
             .unknown,
             .unsupportedProtocol:
            return message.isEmpty ? LocalizedString("The bridge reported an error.", comment: "Bridge error code") : message
        }
    }
}
