import CoreBluetooth
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
    func startScan()
    func stopScan()
}

/// CoreBluetooth central for the bridge GATT service (§1). Runs on `queue`.
///
/// - state restoration (`CBCentralManagerOptionRestoreIdentifierKey`)
/// - connects without timeout so iOS reconnects whenever the bridge is in range
/// - fragmentation (§2), sequential writes with response
public final class BLEBridgeLink: NSObject, BridgeLink, BridgeScanning {
    public static let restoreIdentifier = "org.nightscout.InsightKit.central"

    public weak var delegate: BridgeLinkDelegate?
    public weak var scanDelegate: BridgeScanDelegate?

    public private(set) var state: BridgeLinkState = .stopped {
        didSet { if oldValue != state { delegate?.linkDidChangeState(self) } }
    }

    public var targetPeripheral: UUID? {
        didSet {
            guard oldValue != targetPeripheral else { return }
            if let peripheral, peripheral.identifier != targetPeripheral {
                central?.cancelPeripheralConnection(peripheral)
                self.peripheral = nil
                rx = nil
                tx = nil
            }
        }
    }

    private let queue: DispatchQueue
    private let log = InsightLog(category: "BLEBridgeLink")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var wantsConnection = false
    private var reassembler = Reassembler()
    private var messageSeq: UInt16 = 0

    private struct OutgoingMessage {
        var fragments: [Data]
        var completion: (Error?) -> Void
    }

    private var outbox = [OutgoingMessage]()
    private var writing = false

    private var scanning = false
    private var discovered = [UUID: DiscoveredBridge]()
    private var reassemblyTimer: DispatchWorkItem?

    public init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        // Creating the central here lets iOS deliver restored state at launch.
        central = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: BridgeLink

    public func start() {
        queue.async {
            self.wantsConnection = true
            self.connectIfPossible()
        }
    }

    public func stop() {
        queue.async {
            self.wantsConnection = false
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.cleanupConnection(error: BridgeError.linkLost)
            self.state = .stopped
        }
    }

    public func reset() {
        queue.async {
            guard self.wantsConnection else { return }
            if let peripheral = self.peripheral {
                self.cleanupConnection(error: BridgeError.linkLost)
                self.state = .connecting
                // didDisconnect (or the fallback below) triggers the reconnect.
                self.central?.cancelPeripheralConnection(peripheral)
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.wantsConnection, self.state == .connecting else { return }
                    self.connectIfPossible()
                }
            } else {
                self.connectIfPossible()
            }
        }
    }

    public func send(_ envelope: Data, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.state == .connected, let peripheral = self.peripheral, self.rx != nil else {
                completion(BridgeError.notConnected)
                return
            }
            let mtu = max(peripheral.maximumWriteValueLength(for: .withResponse), 20)
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
            self.scanning = true
            self.discovered = [:]
            self.scanIfPossible()
        }
    }

    public func stopScan() {
        queue.async {
            self.scanning = false
            self.central?.stopScan()
        }
    }

    private func scanIfPossible() {
        guard scanning, let central else { return }
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: [BridgeProtocol.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .unauthorized:
            scanDelegate?
                .scanDidFail(LocalizedString(
                    "Bluetooth access is denied. Allow Bluetooth for Trio in Settings.",
                    comment: "BLE error"
                ))
        case .poweredOff:
            scanDelegate?.scanDidFail(LocalizedString("Bluetooth is turned off.", comment: "BLE error"))
        case .unsupported:
            scanDelegate?.scanDidFail(LocalizedString("Bluetooth is not supported on this device.", comment: "BLE error"))
        default:
            break
        }
    }

    // MARK: connection

    private func connectIfPossible() {
        guard wantsConnection, let central else { return }
        switch central.state {
        case .poweredOn:
            break
        case .unauthorized:
            state =
                .bluetoothUnavailable(LocalizedString(
                    "Bluetooth access is denied. Allow Bluetooth for Trio in Settings.",
                    comment: "BLE error"
                ))
            return
        case .poweredOff:
            state = .bluetoothUnavailable(LocalizedString("Bluetooth is turned off.", comment: "BLE error"))
            return
        case .unsupported:
            state = .bluetoothUnavailable(LocalizedString("Bluetooth is not supported on this device.", comment: "BLE error"))
            return
        default:
            state = .connecting
            return // wait for centralManagerDidUpdateState
        }

        guard let id = targetPeripheral else {
            state = .connecting
            return
        }
        if let peripheral, peripheral.identifier == id {
            switch peripheral.state {
            case .connected:
                if rx != nil, tx != nil, tx?.isNotifying == true {
                    state = .connected
                } else {
                    state = .connecting
                    peripheral.delegate = self
                    peripheral.discoverServices([BridgeProtocol.serviceUUID])
                }
                return
            case .connecting:
                state = .connecting
                return
            default:
                break
            }
        }
        guard let known = central.retrievePeripherals(withIdentifiers: [id]).first else {
            // Not known to iOS (yet): scan for it, a hit gets connected in didDiscover.
            state = .connecting
            central.scanForPeripherals(withServices: [BridgeProtocol.serviceUUID], options: nil)
            return
        }
        peripheral = known
        known.delegate = self
        state = .connecting
        // No timeout: iOS keeps the pending connection and completes it when the bridge is in range.
        central.connect(known, options: nil)
    }

    private func cleanupConnection(error: Error) {
        rx = nil
        tx = nil
        reassembler.reset()
        reassemblyTimer?.cancel()
        let pendingMessages = outbox
        outbox = []
        writing = false
        pendingMessages.forEach { $0.completion(error) }
    }

    private func pumpOutbox() {
        guard !writing, let peripheral, let rx, !outbox.isEmpty else { return }
        guard outbox[0].fragments.isEmpty == false else {
            let done = outbox.removeFirst()
            done.completion(nil)
            pumpOutbox()
            return
        }
        writing = true
        let fragment = outbox[0].fragments.removeFirst()
        peripheral.writeValue(fragment, for: rx, type: .withResponse)
    }

    private func armReassemblyTimer() {
        reassemblyTimer?.cancel()
        guard reassembler.isAssembling else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.reassembler.expire(now: Date()) { self.log.warning("dropped stale partial message") }
        }
        reassemblyTimer = item
        queue.asyncAfter(deadline: .now() + BridgeProtocol.reassemblyTimeout + 0.1, execute: item)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBridgeLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("central state \(central.state.rawValue)")
        scanIfPossible()
        if central.state == .poweredOn {
            if wantsConnection { connectIfPossible() }
        } else {
            cleanupConnection(error: BridgeError.linkLost)
            if wantsConnection { connectIfPossible() }
        }
    }

    public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        log.info("restored bridge peripheral")
        peripheral = restored
        restored.delegate = self
        if targetPeripheral == nil { targetPeripheral = restored.identifier }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        if scanning {
            // The scan is already filtered by service UUID: never filter by name (the bridge no longer advertises one).
            discovered[peripheral.identifier] = DiscoveredBridge(
                id: peripheral.identifier,
                name: BridgeProtocol.displayName(
                    serviceData: advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
                    peripheralName: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ),
                rssi: RSSI.intValue,
                lastSeen: Date()
            )
            scanDelegate?.scanDidUpdate(discovered.values.sorted { $0.rssi > $1.rssi })
        }

        if wantsConnection, peripheral.identifier == targetPeripheral, self.peripheral?.state != .connected {
            if !scanning { central.stopScan() }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("peripheral connected")
        peripheral.delegate = self
        peripheral.discoverServices([BridgeProtocol.serviceUUID])
    }

    public func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error _: Error?) {
        log.warning("failed to connect")
        cleanupConnection(error: BridgeError.linkLost)
        if wantsConnection {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectIfPossible() }
        }
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error _: Error?) {
        log.info("peripheral disconnected")
        cleanupConnection(error: BridgeError.linkLost)
        if wantsConnection {
            state = .connecting
            // Immediately ask iOS to reconnect (no timeout).
            connectIfPossible()
        } else {
            state = .stopped
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBridgeLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BridgeProtocol.serviceUUID }) else {
            log.warning("service discovery failed")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [BridgeProtocol.rxCharacteristicUUID, BridgeProtocol.txCharacteristicUUID], for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        rx = service.characteristics?.first { $0.uuid == BridgeProtocol.rxCharacteristicUUID }
        tx = service.characteristics?.first { $0.uuid == BridgeProtocol.txCharacteristicUUID }
        guard let tx, rx != nil else {
            log.warning("characteristics missing")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else {
            log.warning("could not enable notifications")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        reassembler.reset()
        state = .connected
    }

    public func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == BridgeProtocol.txCharacteristicUUID,
              let value = characteristic.value else { return }
        switch reassembler.accept(value, now: Date()) {
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

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor _: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            log.warning("write failed")
            let pendingMessages = outbox
            outbox = []
            pendingMessages.forEach { $0.completion(error) }
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        if let first = outbox.first, first.fragments.isEmpty {
            outbox.removeFirst()
            first.completion(nil)
        }
        pumpOutbox()
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == BridgeProtocol.serviceUUID }) {
            central?.cancelPeripheralConnection(peripheral)
        }
    }
}
