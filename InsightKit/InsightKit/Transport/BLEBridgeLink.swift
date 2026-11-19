import Foundation

public struct DiscoveredBridge: Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let lastSeen: Date
}

public protocol BridgeScanDelegate: AnyObject {
    func scanDidUpdate(_ devices: [DiscoveredBridge])
    func scanDidFail(_ reason: String)
}

public protocol BridgeScanning: AnyObject {
    var scanDelegate: BridgeScanDelegate? { get set }
    var lastCandidateSeen: Date? { get }
    func startScan()
    func stopScan()
}

/// Bridge connection supervisor (PROTOCOL.md §1a). Runs on `queue`; talks to the radio through `BLECentral`.
///
/// While a connection is wanted and no authenticated session is up it
/// - keeps a pending connect to the last known peripheral identifier,
/// - scans for the service UUID at the same time (Android rotates its BLE address, so the remembered
///   identifier alone goes stale) and connects every discovered candidate that is not on the ignore list,
/// - surfaces ONE GATT-ready candidate at a time (`state == .connected`) so the session layer can run the
///   handshake on it. The session reports the verdict with `markAuthenticated()` (the candidate wins, its
///   identifier is persisted and all others are cancelled) or `rejectCandidate()` (ignored for 10 minutes),
/// - repeats the whole cycle every `retryInterval` (no growing backoff) until a session is authenticated.
///
/// Background note: while the app is suspended nothing here runs until iOS wakes it (a scan hit, a connect completing,
/// a notification). Liveness therefore relies on those wake-ups; the bridge drops an idle ACTIVE link after 15 minutes
/// without an authenticated frame (§1a), and the next wake-up finds the link gone and recovers.
///
/// Also: fragmentation (§2), sequential writes with response, Bluetooth off/on, state restoration.
public final class BLEBridgeLink: BridgeLink, BridgeScanning, BLECentralEvents {
    public static let restoreIdentifier = CoreBluetoothCentral.restoreIdentifier
    /// Pause between recovery cycles (restarting the scan, re-issuing the pending connect). Never grows.
    public static let retryInterval: TimeInterval = 5
    /// A candidate (not the remembered peripheral) whose connect has not completed after this long is dropped.
    public static let candidateConnectTimeout: TimeInterval = 10
    /// Most candidates connected at the same time.
    static let maxParallelCandidates = 3
    /// An unauthenticated connection that ends sooner than this is retried on the next tick, not immediately.
    static let minimumConnectionLife: TimeInterval = 1

    public weak var delegate: BridgeLinkDelegate?
    public weak var scanDelegate: BridgeScanDelegate?

    public private(set) var state: BridgeLinkState = .stopped {
        didSet { if oldValue != state { delegate?.linkDidChangeState(self) } }
    }

    /// Last known (authenticated) peripheral identifier; also the target of the pending connect.
    public var targetPeripheral: UUID? {
        get { lock.withLock { _target } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard _target != newValue else { return false }
                _target = newValue
                return true
            }
            guard changed else { return }
            queue.async {
                // A different bridge was selected: the old connection no longer counts.
                if let current = self.active, current != newValue, self.authenticated { self.dropActive(cancel: true) }
                self.reconcile()
            }
        }
    }

    public var allowsCandidates = true
    public private(set) var connectionGeneration = 0

    public var lastCandidateSeen: Date? { lock.withLock { _lastCandidateSeen } }
    public var ignoredCandidateCount: Int { lock.withLock { _ignoredCount } }

    private let queue: DispatchQueue
    private let central: BLECentral
    private let scheduler: BridgeScheduler
    private let clock: () -> Date
    private let log = InsightLog(category: "BLEBridgeLink")

    private let lock = NSLock()
    private var _lastCandidateSeen: Date?
    private var _ignoredCount = 0
    private var _target: UUID?
    private var _activeIsTarget = false
    private var _expectedBridgeId: String?
    private var scanRunning = false

    private var wantsConnection = false
    /// Connects in flight: identifier -> when started.
    private var connecting = [UUID: Date]()
    /// GATT-ready peripherals, in order of readiness (the first one is promoted when none is active).
    private var ready = [UUID]()
    /// The candidate the session layer is handshaking with, or the authenticated bridge.
    private var active: UUID?
    private var authenticated = false
    private var activeSince = Date.distantPast
    /// Cancelled connections whose `didDisconnect` has not arrived yet (no reconnect before that).
    private var disconnecting = Set<UUID>()
    private var ignored = [UUID: Date]()
    private var retryTimer: BridgeCancellable?

    private var reassembler = Reassembler()
    private var messageSeq: UInt16 = 0
    private var reassemblyTimer: BridgeCancellable?

    private struct OutgoingMessage {
        var fragments: [Data]
        var completion: (Error?) -> Void
    }

    private var outbox = [OutgoingMessage]()
    private var writing = false

    // setup UI scan
    private var uiScanning = false
    private var discovered = [UUID: DiscoveredBridge]()

    public convenience init(queue: DispatchQueue, scheduler: BridgeScheduler? = nil) {
        self.init(
            queue: queue, central: CoreBluetoothCentral(queue: queue),
            scheduler: scheduler ?? DispatchBridgeScheduler(queue: queue)
        )
    }

    public init(
        queue: DispatchQueue, central: BLECentral, scheduler: BridgeScheduler, clock: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.central = central
        self.scheduler = scheduler
        self.clock = clock
        central.events = self
    }

    // MARK: BridgeLink

    public func start() {
        queue.async {
            self.wantsConnection = true
            self.reconcile()
        }
    }

    public func stop() {
        queue.async {
            self.wantsConnection = false
            self.teardownAll()
            self.state = .stopped
        }
    }

    public func reset() {
        queue.async {
            guard self.wantsConnection else { return }
            self.log.info("reset: dropping the connection and searching again")
            self.dropActive(cancel: true)
            self.reconcile()
        }
    }

    public func markAuthenticated(connection: Int) {
        queue.async {
            guard connection == self.connectionGeneration, let id = self.active, !self.authenticated else {
                self.log.info("ignoring a stale authentication verdict")
                return
            }
            self.authenticated = true
            let changed = self.targetPeripheral != id
            self.setTargetSilently(id)
            self.log.info("bridge authenticated (identifier \(changed ? "changed" : "unchanged"))")
            // The first candidate that authenticates wins: cancel everything else, stop searching.
            for other in Array(self.connecting.keys) + self.ready where other != id { self.cancel(other) }
            self.connecting = [:]
            self.ready = [id]
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.scanRunning = false
            if !self.uiScanning { self.central.stopScanning() }
            self.delegate?.link(self, didAdoptPeripheral: id)
        }
    }

    public func rejectCandidate(connection: Int) {
        ignoreActive(connection: connection, for: BridgeProtocol.ignoreDuration, unlessTarget: false)
    }

    public func abandonCandidate(connection: Int) {
        ignoreActive(connection: connection, for: BridgeProtocol.silentIgnoreDuration, unlessTarget: true)
    }

    private func ignoreActive(connection: Int, for duration: TimeInterval, unlessTarget: Bool) {
        queue.async {
            guard connection == self.connectionGeneration, let id = self.active, !self.authenticated else {
                self.log.info("ignoring a stale candidate verdict")
                return
            }
            if !(unlessTarget && id == self.targetPeripheral) {
                self.log.warning("candidate not usable: ignored for \(Int(duration)) s")
                self.ignored[id] = self.clock().addingTimeInterval(duration)
            }
            self.dropActive(cancel: true)
            self.reconcile()
        }
    }

    public var activeIsTarget: Bool { lock.withLock { _activeIsTarget } }
    public var expectedBridgeId: String? {
        get { lock.withLock { _expectedBridgeId } }
        set { lock.withLock { _expectedBridgeId = newValue } }
    }

    public func send(_ envelope: Data, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.state == .connected, let id = self.active else {
                completion(BridgeError.notConnected)
                return
            }
            let mtu = self.central.maximumWriteLength(for: id)
            self.messageSeq &+= 1
            guard let fragments = Fragmenter.fragments(of: envelope, messageSeq: self.messageSeq, maxFragmentSize: mtu) else {
                completion(BridgeError.encoding("fragment"))
                return
            }
            self.outbox.append(OutgoingMessage(fragments: fragments, completion: completion))
            self.pumpOutbox()
        }
    }

    // MARK: scanning (setup UI)

    public func startScan() {
        queue.async {
            self.uiScanning = true
            self.discovered = [:]
            switch self.central.state {
            case .poweredOn: self.central.scanForBridges()
            case .unauthorized:
                self.scanDelegate?.scanDidFail(LocalizedString(
                    "Bluetooth access is denied. Allow Bluetooth for Trio in Settings.", comment: "BLE error"
                ))
            case .poweredOff:
                self.scanDelegate?.scanDidFail(LocalizedString("Bluetooth is turned off.", comment: "BLE error"))
            case .unsupported:
                self.scanDelegate?
                    .scanDidFail(LocalizedString("Bluetooth is not supported on this device.", comment: "BLE error"))
            default: break
            }
        }
    }

    public func stopScan() {
        queue.async {
            self.uiScanning = false
            if !self.isSearching { self.central.stopScanning() }
        }
    }

    // MARK: supervision

    private var isSearching: Bool { wantsConnection && !authenticated }

    private func setTargetSilently(_ id: UUID) {
        let isActive = active == id
        lock.withLock {
            _target = id
            _activeIsTarget = isActive
        }
    }

    private func isIgnored(_ id: UUID) -> Bool {
        guard let until = ignored[id] else { return false }
        if until <= clock() {
            ignored[id] = nil
            return false
        }
        return true
    }

    private func pruneIgnored() {
        let now = clock()
        ignored = ignored.filter { $0.value > now }
        lock.withLock { _ignoredCount = ignored.count }
    }

    private func cancel(_ id: UUID) {
        disconnecting.insert(id)
        central.cancelConnection(id)
        // Do not wait forever for the disconnect callback.
        _ = scheduler.schedule(after: 2) { [weak self] in
            guard let self, self.disconnecting.remove(id) != nil else { return }
            self.reconcile()
        }
    }

    private func dropActive(cancel shouldCancel: Bool) {
        let id = active
        active = nil
        authenticated = false
        if let id {
            ready.removeAll { $0 == id }
            connecting[id] = nil
            if shouldCancel { cancel(id) }
        }
        cleanupConnection(error: BridgeError.linkLost)
        if wantsConnection { state = .connecting }
    }

    private func teardownAll() {
        let all = Set(Array(connecting.keys) + ready + (active.map { [$0] } ?? []))
        connecting = [:]
        ready = []
        active = nil
        authenticated = false
        retryTimer?.cancel()
        retryTimer = nil
        scanRunning = false
        cleanupConnection(error: BridgeError.linkLost)
        for id in all { cancel(id) }
        if !uiScanning { central.stopScanning() }
    }

    private func bluetoothUnavailableReason() -> String? {
        switch central.state {
        case .unauthorized:
            return LocalizedString("Bluetooth access is denied. Allow Bluetooth for Trio in Settings.", comment: "BLE error")
        case .poweredOff:
            return LocalizedString("Bluetooth is turned off.", comment: "BLE error")
        case .unsupported:
            return LocalizedString("Bluetooth is not supported on this device.", comment: "BLE error")
        default: return nil
        }
    }

    /// Brings the radio in line with what is wanted. Idempotent; called on every event and every retry tick.
    private func reconcile() {
        guard wantsConnection else {
            if state != .stopped, active == nil { state = .stopped }
            return
        }
        if let reason = bluetoothUnavailableReason() {
            let hadWork = !connecting.isEmpty || !ready.isEmpty || active != nil
            connecting = [:]
            ready = []
            active = nil
            authenticated = false
            retryTimer?.cancel()
            retryTimer = nil
            scanRunning = false
            if hadWork { cleanupConnection(error: BridgeError.linkLost) }
            state = .bluetoothUnavailable(reason)
            return
        }
        guard central.state == .poweredOn else {
            state = .connecting // resetting / unknown: wait for centralDidUpdateState
            return
        }

        pruneIgnored()
        if authenticated {
            state = .connected
            return
        }

        pruneStaleConnects()

        // Promote the first GATT-ready peripheral that may be used.
        if active == nil {
            let unusable = ready.filter { isIgnored($0) || (!allowsCandidates && $0 != targetPeripheral) }
            ready.removeAll { unusable.contains($0) }
            for id in unusable { cancel(id) }
            if let next = ready.first {
                active = next
                lock.withLock { _activeIsTarget = (next == _target) }
                activeSince = clock()
                connectionGeneration &+= 1
                reassembler.reset()
            }
        }

        if allowsCandidates, !scanRunning {
            scanRunning = true
            central.scanForBridges()
        }

        if let id = targetPeripheral, !isIgnored(id), connecting[id] == nil, !ready.contains(id), !disconnecting.contains(id) {
            connecting[id] = clock() // before connect(): it may report ready synchronously
            if !central.connect(id) { connecting[id] = nil }
        }

        state = active != nil ? .connected : .connecting
        armRetryTimer()
    }

    private var retainedPeripherals: Set<UUID> {
        var keep = Set(connecting.keys).union(ready).union(disconnecting)
        if let active { keep.insert(active) }
        if let target = targetPeripheral { keep.insert(target) }
        return keep
    }

    private func armRetryTimer() {
        guard retryTimer == nil, isSearching else { return }
        retryTimer = scheduler.schedule(after: Self.retryInterval) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.scanRunning = false // restart the scan: iOS then reports known devices again
            self.central.prune(keeping: self.retainedPeripherals)
            self.reconcile()
        }
    }

    // MARK: outgoing

    private func cleanupConnection(error: Error) {
        reassembler.reset()
        reassemblyTimer?.cancel()
        reassemblyTimer = nil
        let pendingMessages = outbox
        outbox = []
        writing = false
        pendingMessages.forEach { $0.completion(error) }
    }

    private func pumpOutbox() {
        guard !writing, let id = active, !outbox.isEmpty else { return }
        guard outbox[0].fragments.isEmpty == false else {
            let done = outbox.removeFirst()
            done.completion(nil)
            pumpOutbox()
            return
        }
        writing = true
        central.write(outbox[0].fragments.removeFirst(), to: id)
    }

    private func armReassemblyTimer() {
        reassemblyTimer?.cancel()
        guard reassembler.isAssembling else { return }
        reassemblyTimer = scheduler.schedule(after: BridgeProtocol.reassemblyTimeout + 0.1) { [weak self] in
            guard let self else { return }
            if self.reassembler.expire(now: Date()) { self.log.warning("dropped stale partial message") }
        }
    }

    // MARK: BLECentralEvents

    public func centralDidUpdateState() {
        log.info("central state changed")
        if central.state != .poweredOn {
            // Everything was invalidated by the radio going away.
            connecting = [:]
            ready = []
            disconnecting = []
            scanRunning = false
            let hadActive = active != nil
            active = nil
            authenticated = false
            if hadActive || !outbox.isEmpty { cleanupConnection(error: BridgeError.linkLost) }
        }
        reconcile()
        if central.state == .poweredOn, uiScanning { central.scanForBridges() }
        if uiScanning, let reason = bluetoothUnavailableReason() { scanDelegate?.scanDidFail(reason) }
    }

    public func central(didRestore peripherals: [UUID]) {
        log.info("restored \(peripherals.count) bridge peripheral(s)")
        for id in peripherals where connecting[id] == nil && !ready.contains(id) { connecting[id] = clock() }
        if targetPeripheral == nil, let first = peripherals.first { setTargetSilently(first) }
        reconcile()
    }

    public func central(didDiscover id: UUID, name: String, rssi: Int, advertisedId: String?) {
        lock.withLock { _lastCandidateSeen = clock() }
        if uiScanning {
            discovered[id] = DiscoveredBridge(id: id, name: name, rssi: rssi, lastSeen: clock())
            scanDelegate?.scanDidUpdate(discovered.values.sorted { $0.rssi > $1.rssi })
        }
        guard isSearching, allowsCandidates, central.state == .poweredOn else { return }
        // Stale entries must not keep a (background) wake-up from admitting the real bridge.
        pruneIgnored()
        pruneStaleConnects()
        // An advertisement that names another bridge is not worth a connection at all.
        guard BridgeProtocol.advertisement(advertisedId, couldBe: expectedBridgeId) else { return }
        let target = targetPeripheral
        let candidatesInUse = connecting.keys.filter { $0 != target }.count + ready.filter { $0 != target }.count
        guard !isIgnored(id), connecting[id] == nil, !ready.contains(id), active != id, !disconnecting.contains(id),
              candidatesInUse < Self.maxParallelCandidates
        else { return }
        log.info("bridge candidate discovered")
        connecting[id] = clock() // before connect(): it may report ready synchronously
        if !central.connect(id) { connecting[id] = nil }
    }

    /// Drops candidate connects that never completed (rotated-away addresses stay pending forever).
    private func pruneStaleConnects() {
        let now = clock()
        for (id, started) in connecting
            where id != targetPeripheral && now.timeIntervalSince(started) > Self.candidateConnectTimeout
        {
            connecting[id] = nil
            cancel(id)
        }
    }

    public func central(didBecomeReady id: UUID) {
        connecting[id] = nil
        if authenticated, id != active {
            cancel(id) // a bridge already won
            return
        }
        if !ready.contains(id) { ready.append(id) }
        reconcile()
    }

    public func central(didFailToConnect id: UUID) {
        log.warning("failed to connect")
        connecting[id] = nil
        // The next recovery tick tries again (never later than `retryInterval`); retrying right here could spin.
        armRetryTimer()
    }

    public func central(didDisconnect id: UUID) {
        log.info("peripheral disconnected")
        disconnecting.remove(id)
        connecting[id] = nil
        ready.removeAll { $0 == id }
        var churn = false
        if id == active {
            // A connection that never got authenticated and dies right away must not be retried in a tight loop.
            churn = !authenticated && clock().timeIntervalSince(activeSince) < Self.minimumConnectionLife
            active = nil
            authenticated = false
            cleanupConnection(error: BridgeError.linkLost)
            if wantsConnection { state = .connecting }
        }
        if churn { armRetryTimer() } else { reconcile() }
    }

    public func central(_ id: UUID, didReceive fragment: Data) {
        guard id == active else { return } // only the candidate being handshaked / the bridge is listened to
        switch reassembler.accept(fragment, now: Date()) {
        case let .complete(message):
            delegate?.link(self, didReceive: message)
        case .incomplete:
            armReassemblyTimer()
        case let .dropped(reason):
            log.warning("dropped fragment: \(reason)")
        case .tooLarge:
            log.warning("incoming message too large")
        }
    }

    public func central(_ id: UUID, didWrite error: Error?) {
        guard id == active else { return }
        writing = false
        if let error {
            log.warning("write failed")
            let pendingMessages = outbox
            outbox = []
            pendingMessages.forEach { $0.completion(error) }
            cancel(id)
            return
        }
        if let first = outbox.first, first.fragments.isEmpty {
            outbox.removeFirst()
            first.completion(nil)
        }
        pumpOutbox()
    }
}
