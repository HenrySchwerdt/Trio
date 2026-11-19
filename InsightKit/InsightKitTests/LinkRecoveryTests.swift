import CryptoKit
@testable import InsightKit
import XCTest

// MARK: - Fake radio

/// One BLE device in the fake radio world: it has a (rotating) identifier, a position (in range or not) and a
/// bridge behind it that speaks the real handshake / encrypted protocol.
final class FakeRadioPeripheral: FakeEndpoint {
    let id: UUID
    var inRange = true
    var advertising = true
    var connected = false
    /// A misbehaving device that accepts the connection and hangs up at once.
    var dropsImmediately = false
    /// Service data of the advertisement (last 4 hex of the bridge id); nil: not advertised.
    var advertisedId: String?
    var onSend: ((Data) -> Void)?
    var bridge: FakeBridge!
    fileprivate weak var central: FakeCentral?
    private var reassembler = Reassembler()
    private var seq: UInt16 = 0

    init(id: UUID = UUID()) { self.id = id }

    /// central -> peripheral write
    fileprivate func receive(fragment: Data) {
        if case let .complete(message) = reassembler.accept(fragment, now: Date()) { onSend?(message) }
    }

    /// peripheral -> central notification
    func deliver(_ envelope: Data) {
        seq &+= 1
        for fragment in Fragmenter.fragments(of: envelope, messageSeq: seq, maxFragmentSize: 512) ?? [] {
            central?.notify(id, fragment)
        }
    }
}

final class FakeCentral: BLECentral {
    weak var events: BLECentralEvents?
    var state: BLECentralState = .poweredOn
    let queue: DispatchQueue
    private(set) var peripherals = [UUID: FakeRadioPeripheral]()
    private(set) var scanning = false
    private(set) var scanStarts = 0
    private(set) var connectRequests = [UUID]()
    private(set) var cancelled = [UUID]()
    private var pending = Set<UUID>()
    /// Report readiness synchronously from `connect` (what the real adapter does for an already connected peripheral).
    var syncReady = false
    private(set) var lastPruneKeep = Set<UUID>()
    func prune(keeping ids: Set<UUID>) { lastPruneKeep = ids }

    init(queue: DispatchQueue) { self.queue = queue }

    func add(_ peripheral: FakeRadioPeripheral) {
        peripheral.central = self
        peripherals[peripheral.id] = peripheral
    }

    func connectRequestCount(_ id: UUID) -> Int { connectRequests.filter { $0 == id }.count }

    // BLECentral

    func scanForBridges() {
        scanning = true
        scanStarts += 1
        for p in peripherals.values where p.advertising {
            queue
                .async {
                    self.events?.central(didDiscover: p.id, name: "InsightBridge-TEST", rssi: -50, advertisedId: p.advertisedId) }
        }
    }

    func stopScanning() { scanning = false }

    func connect(_ id: UUID) -> Bool {
        guard state == .poweredOn, let p = peripherals[id] else { return false }
        connectRequests.append(id)
        if !p.connected { pending.insert(id) }
        completePending(p)
        return true
    }

    func cancelConnection(_ id: UUID) {
        cancelled.append(id)
        pending.remove(id)
        guard let p = peripherals[id], p.connected else { return }
        p.connected = false
        queue.async { self.events?.central(didDisconnect: id) }
    }

    func write(_ fragment: Data, to id: UUID) {
        guard let p = peripherals[id], p.connected else {
            queue.async { self.events?.central(id, didWrite: BridgeError.notConnected) }
            return
        }
        p.receive(fragment: fragment)
        queue.async { self.events?.central(id, didWrite: nil) }
    }

    func maximumWriteLength(for _: UUID) -> Int { 512 }

    // world control

    private func completePending(_ p: FakeRadioPeripheral) {
        guard pending.contains(p.id), p.inRange, state == .poweredOn else { return }
        pending.remove(p.id)
        p.connected = true
        if syncReady { events?.central(didBecomeReady: p.id) } else { queue.async { self.events?.central(didBecomeReady: p.id) } }
        if p.dropsImmediately {
            queue.async {
                p.connected = false
                self.events?.central(didDisconnect: p.id)
            }
        }
    }

    fileprivate func notify(_ id: UUID, _ fragment: Data) {
        queue.async { self.events?.central(id, didReceive: fragment) }
    }

    /// A device comes into range: pending connects to it complete.
    func enterRange(_ p: FakeRadioPeripheral) {
        p.inRange = true
        completePending(p)
        if scanning,
           p
           .advertising
        {
            queue
                .async {
                    self.events?.central(didDiscover: p.id, name: "InsightBridge-TEST", rssi: -50, advertisedId: p.advertisedId)
                } }
    }

    /// The remote side drops the link (bridge restart, walking out of range, address rotation).
    func dropFromPeripheral(_ p: FakeRadioPeripheral, leaveRange: Bool) {
        if leaveRange { p.inRange = false
            p.advertising = false }
        guard p.connected else { return }
        p.connected = false
        queue.async { self.events?.central(didDisconnect: p.id) }
    }

    /// Bluetooth switched off / on on the iPhone.
    func setPower(_ on: Bool) {
        state = on ? .poweredOn : .poweredOff
        if !on {
            pending = []
            scanning = false
            for p in peripherals.values { p.connected = false }
        }
        queue.async { self.events?.centralDidUpdateState() }
    }
}

// MARK: - World

private final class AdoptSpy: BridgeSessionDelegate {
    var adopted = [UUID]()
    var states = [BridgeSessionState]()
    func sessionDidChangeState(_ session: BridgeSession) { states.append(session.state) }
    func session(_: BridgeSession, didReceive _: BridgeEvent) {}
    func session(_: BridgeSession, didAdoptPeripheral id: UUID) { adopted.append(id) }
}

class LinkWorldTestCase: XCTestCase {
    let queue = DispatchQueue(label: "test.linkworld")
    let scheduler = ManualScheduler()
    let store = InMemoryCredentialStore()
    var central: FakeCentral!
    var link: BLEBridgeLink!
    var session: BridgeSession!
    fileprivate let spy = AdoptSpy()
    let ltk = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))
    let pairedBridgeId = "00112233aabbccdd"

    override func setUp() {
        super.setUp()
        central = FakeCentral(queue: queue)
        link = BLEBridgeLink(
            queue: queue, central: central, scheduler: scheduler,
            clock: { [unowned self] in self.now }
        )
        try? store.save(BridgeCredentials(
            bridgeId: pairedBridgeId, ltk: ltk.withUnsafeBytes { Data($0) }, clientId: "0102030405060708"
        ))
        session = BridgeSession(
            link: link, store: store, scheduler: scheduler, queue: queue, appName: "Trio test",
            clock: { [unowned self] in self.now }
        )
        session.delegate = spy
    }

    /// Wall clock: scheduler time plus time that passed while the app was suspended (timers did not run).
    var suspendedTime: TimeInterval = 0
    var now: Date { Date(timeIntervalSince1970: 1_000_000 + scheduler.now + suspendedTime) }

    func settle() { for _ in 0 ..< 12 { queue.sync {} } }

    func advance(_ seconds: TimeInterval) {
        // in one second steps so timers set by earlier timers also fire
        var left = seconds
        while left > 0 {
            let step = min(left, 1)
            queue.sync { scheduler.advance(by: step) }
            settle()
            left -= step
        }
    }

    /// A bridge device. `bridgeId`/`ltk` default to the paired bridge.
    @discardableResult func makeBridge(
        bridgeId: String? = nil, ltk: SymmetricKey? = nil, inRange: Bool = true, advertising: Bool = true
    ) -> FakeRadioPeripheral {
        let p = FakeRadioPeripheral()
        p.inRange = inRange
        p.advertising = advertising
        p.bridge = FakeBridge(link: p, bridgeId: bridgeId ?? pairedBridgeId, ltk: ltk ?? self.ltk)
        central.add(p)
        return p
    }

    func startSession(target: FakeRadioPeripheral?) {
        session.start(bridgeId: pairedBridgeId, peripheral: target?.id)
        settle()
    }

    var targetId: UUID? { link.targetPeripheral }
}

// MARK: - Tests

final class LinkRecoveryTests: LinkWorldTestCase {
    func testConnectsToRememberedPeripheralAndCommitsIt() {
        let a = makeBridge()
        startSession(target: a)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(targetId, a.id)
        XCTAssertFalse(central.scanning, "scanning stops while a session is up (§1a.4)")
        XCTAssertEqual(link.connectionGeneration, 1)
    }

    func testSearchesWhileConnectingToRememberedIdentifier() {
        // The remembered peripheral is out of range: a pending connect AND a scan run at the same time.
        let a = makeBridge(inRange: false, advertising: false)
        startSession(target: a)
        XCTAssertEqual(central.connectRequestCount(a.id), 1)
        XCTAssertTrue(central.scanning)
        XCTAssertEqual(session.state, .linkConnecting)
    }

    func testAddressRotationReconnectsToTheNewIdentifierWithinOneScanCycle() {
        let old = makeBridge()
        startSession(target: old)
        XCTAssertEqual(session.state, .ready)

        // Android rotates its address: the old identifier vanishes, the same bridge shows up under a new one
        // a little later (after the link dropped).
        central.dropFromPeripheral(old, leaveRange: true)
        settle()
        XCTAssertEqual(session.state, .linkConnecting, "the link drop is noticed immediately")
        let new = makeBridge(advertising: false)
        advance(2)
        XCTAssertEqual(session.state, .linkConnecting)
        new.advertising = true
        advance(BLEBridgeLink.retryInterval) // one scan cycle
        XCTAssertEqual(session.state, .ready, "found through the scan although the old identifier is gone")
        XCTAssertEqual(targetId, new.id, "the new identifier is remembered")
        XCTAssertEqual(spy.adopted.last, new.id, "and reported so that it gets persisted")
        XCTAssertFalse(central.scanning)
    }

    func testWrongBridgeCandidateIsIgnoredForTenMinutesThenRetried() {
        let stranger = makeBridge(bridgeId: "ffeeddccbbaa9988", ltk: SymmetricKey(data: Data(repeating: 9, count: 32)))
        let paired = makeBridge(inRange: false, advertising: false)
        startSession(target: nil)
        XCTAssertEqual(central.connectRequestCount(stranger.id), 1)
        XCTAssertNotEqual(session.state, .ready)
        XCTAssertEqual(session.state, .linkConnecting)
        XCTAssertEqual(link.ignoredCandidateCount, 1)

        // The paired bridge appears: it wins, the stranger is not touched again.
        paired.advertising = true
        central.enterRange(paired)
        advance(BLEBridgeLink.retryInterval)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(targetId, paired.id)
        XCTAssertEqual(central.connectRequestCount(stranger.id), 1)

        // After the link drops and 10 minutes passed the stranger would be tried again (the ignore list expired).
        central.dropFromPeripheral(paired, leaveRange: true)
        advance(BridgeProtocol.ignoreDuration + 1)
        XCTAssertGreaterThanOrEqual(central.connectRequestCount(stranger.id), 2)
    }

    func testWrongBridgeNotRetriedWhileSearching() {
        let stranger = makeBridge(bridgeId: "ffeeddccbbaa9988")
        startSession(target: nil)
        advance(300)
        XCTAssertEqual(central.connectRequestCount(stranger.id), 1, "on the ignore list for 10 minutes")
    }

    func testHalfOpenLinkIsDetectedByPingTimeoutAndRecovers() {
        let a = makeBridge()
        startSession(target: a)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(a.bridge.count("hello"), 1)

        // The radio link looks fine but the bridge no longer answers.
        a.bridge.handler = { op, _ in op == "ping" ? .silent : .ok(.object([:])) }
        advance(BridgeProtocol.pingInterval)
        XCTAssertEqual(a.bridge.count("ping"), 1)
        XCTAssertEqual(session.state, .ready, "not decided before the ping timeout")
        a.bridge.handler = { _, _ in .ok(.object([:])) } // the bridge is back (it was only stuck)
        advance(BridgeProtocol.pingTimeout)
        XCTAssertEqual(a.bridge.count("hello"), 2, "link was cancelled and a new session was started")
        XCTAssertEqual(session.state, .ready)
        XCTAssertTrue(central.cancelled.contains(a.id))
    }

    func testHealthyLinkIsPingedEveryMinuteAndStaysUp() {
        let a = makeBridge()
        startSession(target: a)
        advance(BridgeProtocol.pingInterval * 3 + 5)
        XCTAssertEqual(a.bridge.count("ping"), 3)
        XCTAssertEqual(a.bridge.count("hello"), 1)
        XCTAssertEqual(session.state, .ready)
    }

    func testBridgeAppRestartStartsAFreshSession() {
        let a = makeBridge()
        startSession(target: a)
        let oldGeneration = link.connectionGeneration
        // The bridge app restarts: new process, new session keys, same BLE device.
        a.bridge = FakeBridge(link: a, bridgeId: pairedBridgeId, ltk: ltk)
        central.dropFromPeripheral(a, leaveRange: false)
        settle()
        XCTAssertEqual(session.state, .ready, "pending connect to the same identifier completed again")
        XCTAssertGreaterThan(link.connectionGeneration, oldGeneration)
        XCTAssertEqual(a.bridge.count("hello"), 1, "handshake with the new process")
    }

    func testBluetoothOffAndOn() {
        let a = makeBridge()
        startSession(target: a)
        central.setPower(false)
        settle()
        if case .bluetoothUnavailable = session.state {} else { XCTFail("state \(session.state)") }
        central.setPower(true)
        settle()
        XCTAssertEqual(session.state, .ready, "reconnects by itself when Bluetooth is back")
        XCTAssertEqual(a.bridge.count("hello"), 2)
    }

    func testPhoneRebootOfTheBridgeAndWalkingOutOfRangeAndBack() {
        let a = makeBridge()
        startSession(target: a)
        central.dropFromPeripheral(a, leaveRange: true) // out of range / Android off
        advance(120)
        XCTAssertEqual(session.state, .linkConnecting)
        XCTAssertTrue(central.scanning, "keeps looking")
        a.bridge = FakeBridge(link: a, bridgeId: pairedBridgeId, ltk: ltk)
        a.advertising = true
        central.enterRange(a) // back in range
        advance(BLEBridgeLink.retryInterval)
        XCTAssertEqual(session.state, .ready)
    }

    func testRetryCadenceNeverBacksOff() {
        let a = makeBridge(inRange: false, advertising: false)
        startSession(target: a)
        let first = central.scanStarts
        advance(BLEBridgeLink.retryInterval * 40) // 200 s
        XCTAssertEqual(central.scanStarts - first, 40, "one scan restart every 5 s, also after minutes")
        XCTAssertEqual(central.connectRequestCount(a.id), 1, "one pending connect, not a new one per tick")
    }

    func testCandidatesThatNeverConnectAreDropped() {
        let ghost = makeBridge(inRange: false) // advertised once, cannot be connected
        startSession(target: nil)
        XCTAssertEqual(central.connectRequestCount(ghost.id), 1)
        advance(BLEBridgeLink.candidateConnectTimeout + BLEBridgeLink.retryInterval)
        XCTAssertTrue(central.cancelled.contains(ghost.id))
    }

    func testPairingModeOnlyUsesTheChosenPeripheral() {
        let chosen = makeBridge(advertising: false)
        let other = makeBridge()
        link.allowsCandidates = false
        link.targetPeripheral = chosen.id
        link.start()
        settle()
        XCTAssertEqual(central.connectRequestCount(other.id), 0)
        XCTAssertEqual(link.state, .connected)
    }

    func testStateRestorationReattachesWithoutUserAction() {
        let a = makeBridge()
        a.connected = true // iOS kept the connection while the app was gone
        queue.sync { link.central(didRestore: [a.id]) }
        settle()
        queue.sync { link.central(didBecomeReady: a.id) } // the adapter redid the GATT setup of the restored peripheral
        settle()
        startSession(target: a)
        XCTAssertEqual(session.state, .ready)
    }

    func testDeviceThatHangsUpImmediatelyIsNotRetriedInATightLoop() {
        let flaky = makeBridge()
        flaky.dropsImmediately = true
        startSession(target: flaky)
        settle()
        XCTAssertLessThanOrEqual(central.connectRequestCount(flaky.id), 3, "paced by the retry tick, not spinning")
        let before = central.connectRequestCount(flaky.id)
        advance(BLEBridgeLink.retryInterval * 4)
        XCTAssertLessThanOrEqual(central.connectRequestCount(flaky.id) - before, 8)
    }

    func testStopEndsEverything() {
        let a = makeBridge()
        startSession(target: a)
        session.stop()
        settle()
        XCTAssertEqual(link.state, .stopped)
        XCTAssertFalse(central.scanning)
        advance(30)
        XCTAssertEqual(central.connectRequestCount(a.id), 1)
    }

    func testWakeUpPingsAtOnceWhenTheLastExchangeIsOlderThanAMinute() {
        let a = makeBridge()
        startSession(target: a)
        session.ensureStarted()
        settle()
        XCTAssertEqual(a.bridge.count("ping"), 0, "the link was used a moment ago")
        suspendedTime = 120 // the app slept; no timer ran
        session.ensureStarted()
        settle()
        XCTAssertEqual(a.bridge.count("ping"), 1, "stale: ping right away to keep the link warm")
        session.ensureStarted()
        settle()
        XCTAssertEqual(a.bridge.count("ping"), 1, "the ping answer just refreshed the link")
    }
}
