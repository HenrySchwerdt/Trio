import Foundation
import Security

// MARK: - Scheduler (injectable so timeouts are testable)

public protocol BridgeCancellable: AnyObject {
    func cancel()
}

public protocol BridgeScheduler: AnyObject {
    func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> BridgeCancellable
}

public final class DispatchBridgeScheduler: BridgeScheduler {
    private final class Token: BridgeCancellable {
        private var item: DispatchWorkItem?
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item?.cancel()
            item = nil }
    }

    private let queue: DispatchQueue
    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) -> BridgeCancellable {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + interval, execute: item)
        return Token(item)
    }
}

// MARK: - Link

public enum BridgeLinkState: Equatable {
    /// Not trying to connect.
    case stopped
    case bluetoothUnavailable(String)
    case connecting
    /// GATT characteristics discovered and notifications enabled.
    case connected
}

public protocol BridgeLinkDelegate: AnyObject {
    func linkDidChangeState(_ link: BridgeLink)
    /// A complete, reassembled envelope (§3).
    func link(_ link: BridgeLink, didReceive envelope: Data)
    /// The authenticated bridge is now reachable under this peripheral identifier (§1a: it may have changed
    /// because the bridge rotated its BLE address). Persist it.
    func link(_ link: BridgeLink, didAdoptPeripheral id: UUID)
}

public extension BridgeLinkDelegate {
    func link(_: BridgeLink, didAdoptPeripheral _: UUID) {}
}

/// Message-level pipe to the bridge. The BLE implementation does fragmentation, MTU handling
/// and reconnects; tests use a fake. All delegate callbacks happen on the manager queue.
public protocol BridgeLink: AnyObject {
    var delegate: BridgeLinkDelegate? { get set }
    var state: BridgeLinkState { get }
    /// The last known bridge (CoreBluetooth peripheral identifier). Only a starting point: the address rotates.
    var targetPeripheral: UUID? { get set }
    /// Begin (and keep) looking for the bridge (§1a). Idempotent.
    func start()
    /// Disconnect and stop reconnecting.
    func stop()
    /// Drop the current connection (it may be half-open) and search again.
    func reset()
    /// `false` while pairing: only `targetPeripheral` may be used, no other candidate is connected.
    var allowsCandidates: Bool { get set }
    /// The connection `connection` (a `connectionGeneration`) has completed the session handshake as the paired
    /// bridge (§1a.2): it becomes the new `targetPeripheral`, scanning stops and all other attempts are cancelled.
    /// Ignored if that connection is no longer the active one (a late verdict must never apply to another device).
    func markAuthenticated(connection: Int)
    /// The connection is not the paired bridge (reject / wrong id / MAC failure): disconnect it, ignore it for
    /// 10 minutes and continue with the next candidate. Ignored if `connection` is no longer the active one.
    func rejectCandidate(connection: Int)
    /// The connection never completed the handshake (silent device). Ignored for a short while, unless it is the
    /// remembered bridge itself (that one is simply retried).
    func abandonCandidate(connection: Int)
    /// The active connection is the remembered (persisted) bridge identifier.
    var activeIsTarget: Bool { get }
    /// The bridge id this phone is paired with. Advertisements that name another bridge are not connected to.
    var expectedBridgeId: String? { get set }
    /// When a bridge advertisement was last seen (nil: none since launch).
    var lastCandidateSeen: Date? { get }
    /// Incremented every time a (new) connection becomes `.connected`, also when the state itself did not change
    /// (a candidate replaced another one). The session restarts its handshake when this changes.
    var connectionGeneration: Int { get }
    /// Sends one envelope. The completion reports failure to deliver all fragments.
    func send(_ envelope: Data, completion: @escaping (Error?) -> Void)
}

// MARK: - Credentials

public struct BridgeCredentials: Equatable {
    public let bridgeId: String
    public let ltk: Data
    public let clientId: String

    public init(bridgeId: String, ltk: Data, clientId: String) {
        self.bridgeId = bridgeId
        self.ltk = ltk
        self.clientId = clientId
    }
}

public protocol BridgeCredentialStoring: AnyObject {
    func load(bridgeId: String) -> BridgeCredentials?
    func save(_ credentials: BridgeCredentials) throws
    func delete(bridgeId: String)
}

/// Keychain storage, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the LTK never leaves
/// this device (no backup/migration) but is readable while the phone is locked in the background.
public final class KeychainCredentialStore: BridgeCredentialStoring {
    public static let service = "org.nightscout.InsightKit.bridge"

    public struct KeychainError: Error { public let status: OSStatus }

    public init() {}

    private func baseQuery(_ bridgeId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: bridgeId
        ]
    }

    public func load(bridgeId: String) -> BridgeCredentials? {
        var query = baseQuery(bridgeId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ltkB64 = object["ltk"], let ltk = Data(base64Encoded: ltkB64), ltk.count == 32,
              let clientId = object["clientId"]
        else { return nil }
        return BridgeCredentials(bridgeId: bridgeId, ltk: ltk, clientId: clientId)
    }

    public func save(_ credentials: BridgeCredentials) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "ltk": credentials.ltk.base64EncodedString(),
            "clientId": credentials.clientId
        ])
        let query = baseQuery(credentials.bridgeId)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(bridgeId: String) {
        SecItemDelete(baseQuery(bridgeId) as CFDictionary)
    }
}

/// For tests and previews.
public final class InMemoryCredentialStore: BridgeCredentialStoring {
    private var items = [String: BridgeCredentials]()
    public init() {}
    public func load(bridgeId: String) -> BridgeCredentials? { items[bridgeId] }
    public func save(_ credentials: BridgeCredentials) throws { items[credentials.bridgeId] = credentials }
    public func delete(bridgeId: String) { items[bridgeId] = nil }
}
