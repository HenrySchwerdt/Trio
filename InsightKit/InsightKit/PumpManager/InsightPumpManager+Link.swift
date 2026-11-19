import Foundation

/// How the connection to the InsightBridge app looks to the user (settings screen, status badge).
public enum InsightLinkStatus: Equatable {
    case connected
    /// Searching for the bridge since `since`; advertisements were seen recently, so it is only a matter of time.
    case reconnecting(since: Date)
    /// Searching for a while and no bridge advertisement was seen at all: phone off, app killed, out of range.
    case bridgeNotFound(since: Date)
    case bluetoothUnavailable(String)
    case needsRepair
    case incompatible
    case pairing
    case idle
}

public extension InsightPumpManager {
    /// Searching this long without ever seeing the bridge's advertisement is reported as "bridge not found".
    static let bridgeNotFoundAfter: TimeInterval = 90

    var linkStatus: InsightLinkStatus {
        Self.linkStatus(
            connection: connection, lostSince: connectionLostSinceStore.value ?? state.lastBridgeContact,
            lastSighting: client.lastBridgeSighting, now: clock()
        )
    }

    static func linkStatus(
        connection: BridgeSessionState, lostSince: Date?, lastSighting: Date?, now: Date
    ) -> InsightLinkStatus {
        switch connection {
        case .ready: return .connected
        case let .bluetoothUnavailable(reason): return .bluetoothUnavailable(reason)
        case .needsRepair: return .needsRepair
        case .incompatible: return .incompatible
        case .pairing: return .pairing
        case .handshaking,
             .idle,
             .linkConnecting:
            if case .idle = connection, lostSince == nil { return .idle }
            let since = lostSince ?? now
            guard now.timeIntervalSince(since) >= bridgeNotFoundAfter else { return .reconnecting(since: since) }
            // Seen at all since the connection was lost? Then the bridge is around, just not authenticated yet.
            if let seen = lastSighting, seen >= since { return .reconnecting(since: since) }
            return .bridgeNotFound(since: since)
        }
    }
}
