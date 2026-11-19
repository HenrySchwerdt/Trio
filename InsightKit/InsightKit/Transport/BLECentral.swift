import CoreBluetooth
import Foundation

/// The parts of CoreBluetooth that the bridge link needs, behind a protocol so that the connection logic
/// (candidate search, address rotation, recovery) can be unit tested with a fake radio. Peripherals are
/// identified by their CoreBluetooth identifier. All callbacks arrive on the link's queue.
public enum BLECentralState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public protocol BLECentralEvents: AnyObject {
    func centralDidUpdateState()
    /// iOS relaunched the app for this central: peripherals that were connected / connecting.
    func central(didRestore peripherals: [UUID])
    /// `advertisedId`: the service data of the advertisement (last 4 hex of the bridge id), if present.
    func central(didDiscover id: UUID, name: String, rssi: Int, advertisedId: String?)
    /// GATT characteristics discovered and notifications enabled: envelopes can be exchanged.
    func central(didBecomeReady id: UUID)
    func central(didFailToConnect id: UUID)
    func central(didDisconnect id: UUID)
    func central(_ id: UUID, didReceive fragment: Data)
    func central(_ id: UUID, didWrite error: Error?)
}

public protocol BLECentral: AnyObject {
    var events: BLECentralEvents? { get set }
    var state: BLECentralState { get }
    /// Scans for the bridge service UUID (restarting a running scan, which makes iOS report known devices again).
    func scanForBridges()
    func stopScanning()
    /// Starts a connection without timeout (iOS keeps it pending). False if the identifier is unknown to iOS.
    func connect(_ id: UUID) -> Bool
    func cancelConnection(_ id: UUID)
    /// One write with response to the rx characteristic.
    func write(_ fragment: Data, to id: UUID)
    func maximumWriteLength(for id: UUID) -> Int
    /// Forget cached peripherals that are not in `ids` (and not connected).
    func prune(keeping ids: Set<UUID>)
}

public extension BLECentral {
    func prune(keeping _: Set<UUID>) {}
}

// MARK: - CoreBluetooth implementation

public final class CoreBluetoothCentral: NSObject, BLECentral {
    public static let restoreIdentifier = "org.nightscout.InsightKit.central"

    public weak var events: BLECentralEvents?

    private let log = InsightLog(category: "CoreBluetoothCentral")
    private var central: CBCentralManager!
    private var peripherals = [UUID: CBPeripheral]()
    private var rx = [UUID: CBCharacteristic]()
    private var tx = [UUID: CBCharacteristic]()

    public init(queue: DispatchQueue) {
        super.init()
        // Creating the central right away lets iOS deliver restored state at launch.
        central = CBCentralManager(
            delegate: self, queue: queue, options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    public var state: BLECentralState {
        switch central.state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        default: return .unknown
        }
    }

    public func scanForBridges() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(
            withServices: [BridgeProtocol.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func stopScanning() { central.stopScan() }

    public func connect(_ id: UUID) -> Bool {
        guard central.state == .poweredOn else { return false }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        peripherals[id] = peripheral
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            if tx[id]?.isNotifying == true { events?.central(didBecomeReady: id) } else {
                peripheral.discoverServices([BridgeProtocol.serviceUUID])
            }
        case .connecting,
             .disconnecting:
            break
        default:
            central.connect(peripheral, options: nil)
        }
        return true
    }

    public func cancelConnection(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        rx[id] = nil
        tx[id] = nil
        central.cancelPeripheralConnection(peripheral)
    }

    public func write(_ fragment: Data, to id: UUID) {
        guard let peripheral = peripherals[id], let rx = rx[id] else {
            events?.central(id, didWrite: BridgeError.notConnected)
            return
        }
        peripheral.writeValue(fragment, for: rx, type: .withResponse)
    }

    public func prune(keeping ids: Set<UUID>) {
        for (id, peripheral) in peripherals where !ids.contains(id) {
            switch peripheral.state {
            case .connected,
                 .connecting: continue
            default: peripherals[id] = nil
            }
        }
    }

    public func maximumWriteLength(for id: UUID) -> Int {
        max(peripherals[id]?.maximumWriteValueLength(for: .withResponse) ?? 20, 20)
    }
}

extension CoreBluetoothCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("central state \(central.state.rawValue)")
        if central.state != .poweredOn {
            // CBPeripheral objects from before a power cycle are invalid.
            peripherals = [:]
            rx = [:]
            tx = [:]
        }
        events?.centralDidUpdateState()
    }

    public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log.info("restored \(restored.count) peripheral(s)")
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            // A peripheral that is still connected needs its GATT setup redone (the app was relaunched).
            if peripheral.state == .connected { peripheral.discoverServices([BridgeProtocol.serviceUUID]) }
        }
        events?.central(didRestore: restored.map(\.identifier))
    }

    public func centralManager(
        _: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        // Scan is filtered by service UUID; never filter by name (the bridge no longer advertises one).
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let name = BridgeProtocol.displayName(
            serviceData: serviceData,
            peripheralName: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        )
        events?.central(
            didDiscover: peripheral.identifier, name: name, rssi: RSSI.intValue,
            advertisedId: BridgeProtocol.advertisedId(serviceData: serviceData)
        )
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BridgeProtocol.serviceUUID])
    }

    public func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error _: Error?) {
        events?.central(didFailToConnect: peripheral.identifier)
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        rx[peripheral.identifier] = nil
        tx[peripheral.identifier] = nil
        events?.central(didDisconnect: peripheral.identifier)
    }
}

extension CoreBluetoothCentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BridgeProtocol.serviceUUID }) else {
            log.warning("service discovery failed")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [BridgeProtocol.rxCharacteristicUUID, BridgeProtocol.txCharacteristicUUID], for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        guard error == nil,
              let rxChar = service.characteristics?.first(where: { $0.uuid == BridgeProtocol.rxCharacteristicUUID }),
              let txChar = service.characteristics?.first(where: { $0.uuid == BridgeProtocol.txCharacteristicUUID })
        else {
            log.warning("characteristics missing")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        rx[id] = rxChar
        tx[id] = txChar
        peripheral.setNotifyValue(true, for: txChar)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else {
            log.warning("could not enable notifications")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        events?.central(didBecomeReady: peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == BridgeProtocol.txCharacteristicUUID,
              let value = characteristic.value else { return }
        events?.central(peripheral.identifier, didReceive: value)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor _: CBCharacteristic, error: Error?) {
        events?.central(peripheral.identifier, didWrite: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == BridgeProtocol.serviceUUID }) {
            central.cancelPeripheralConnection(peripheral)
        }
    }
}
