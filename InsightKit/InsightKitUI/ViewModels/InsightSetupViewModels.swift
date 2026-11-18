import Combine
import Foundation
import LoopKit
import LoopKitUI

// MARK: - Scan

final class InsightScanViewModel: ObservableObject, BridgeScanDelegate {
    @Published var devices: [DiscoveredBridge] = []
    @Published var errorMessage: String?
    @Published var showTroubleshooting = false

    private let manager: InsightPumpManager
    private var hintTimer: Timer?

    init(manager: InsightPumpManager) {
        self.manager = manager
    }

    func start() {
        errorMessage = nil
        devices = []
        showTroubleshooting = false
        manager.startScan(delegate: self)
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.showTroubleshooting = true }
        }
    }

    func stop() {
        hintTimer?.invalidate()
        manager.stopScan()
    }

    func scanDidUpdate(_ devices: [DiscoveredBridge]) {
        DispatchQueue.main.async {
            self.devices = devices
            self.errorMessage = nil
            if !devices.isEmpty { self.showTroubleshooting = false }
        }
    }

    func scanDidFail(_ reason: String) {
        DispatchQueue.main.async { self.errorMessage = reason }
    }
}

// MARK: - Pairing

final class InsightPairingViewModel: ObservableObject {
    enum Failure: Equatable {
        case notInPairingMode
        case timeout
        case rejected
        case bluetooth
        case other
    }

    enum Phase: Equatable {
        case connecting
        case confirmCode(String)
        case waitingForBridgeConfirmation
        case done
        case failed(Failure, String)
    }

    @Published var phase: Phase = .connecting

    let device: DiscoveredBridge
    private let manager: InsightPumpManager
    private let onDone: () -> Void

    init(manager: InsightPumpManager, device: DiscoveredBridge, onDone: @escaping () -> Void) {
        self.manager = manager
        self.device = device
        self.onDone = onDone
    }

    func start() {
        phase = .connecting
        manager.beginPairing(with: device) { [weak self] event in
            guard let self else { return }
            switch event {
            case .waitingForBridge:
                self.phase = .connecting
            case let .confirmCode(code):
                self.phase = .confirmCode(code)
            case .waitingForBridgeConfirmation:
                self.phase = .waitingForBridgeConfirmation
            case .completed:
                self.phase = .done
            case let .failed(error):
                self.phase = .failed(Self.failure(for: error), error.localizedDescription)
            }
        }
    }

    func codesMatch() {
        manager.confirmPairingCode(matches: true)
    }

    func cancel() {
        manager.cancelPairing()
    }

    func codesDoNotMatch() {
        manager.confirmPairingCode(matches: false)
    }

    func finish() { onDone() }

    static func failure(for error: BridgeError) -> Failure {
        switch error {
        case let .pairingRejected(reason): return reason == "notInPairingMode" ? .notInPairingMode : .rejected
        case .timeout: return .timeout
        case .bluetoothUnavailable: return .bluetooth
        default: return .other
        }
    }
}

// MARK: - Pump check

final class InsightPumpCheckViewModel: ObservableObject {
    struct Summary: Equatable {
        let serial: String?
        let firmware: String?
        let reservoir: Double?
        let battery: Double?
        let isSimulated: Bool
    }

    enum Phase: Equatable {
        case checking
        case success(Summary)
        case failed(String, noPump: Bool)
    }

    @Published var phase: Phase = .checking
    private let manager: InsightPumpManager

    init(manager: InsightPumpManager) {
        self.manager = manager
    }

    func check() {
        phase = .checking
        manager.checkPump { [weak self] result in
            switch result {
            case let .success(status):
                let simulated = status.serial == InsightPumpManager.simulatorSerial
                self?.phase = .success(Summary(
                    serial: status.serial, firmware: status.firmware, reservoir: status.reservoir?.units,
                    battery: status.battery?.percent, isSimulated: simulated
                ))
            case let .failure(error):
                var noPump = false
                if case let .remote(remote) = error, remote.code == .notPaired { noPump = true }
                self?.phase = .failed(error.localizedDescription, noPump: noPump)
            }
        }
    }
}

// MARK: - Finish (settings sync)

final class InsightFinishViewModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case syncing
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var insulinType: InsulinType

    let allowedInsulinTypes: [InsulinType]
    let isSimulated: Bool
    private let manager: InsightPumpManager
    private let settings: PumpManagerSetupSettings?
    private let onDone: () -> Void

    init(
        manager: InsightPumpManager, settings: PumpManagerSetupSettings?, allowedInsulinTypes: [InsulinType],
        onDone: @escaping () -> Void
    ) {
        self.manager = manager
        self.settings = settings
        self.allowedInsulinTypes = allowedInsulinTypes
        self.onDone = onDone
        isSimulated = manager.state.isSimulated
        insulinType = manager.state.insulinType ?? allowedInsulinTypes.first ?? .novolog
    }

    var scheduleSummary: String {
        guard let settings else { return L("Basal schedule: unchanged") }
        let items = settings.basalSchedule.items
        return L("Basal schedule: %d entries", items.count)
    }

    func sync() {
        phase = .syncing
        guard let settings else {
            // Re-setup of an existing pump without new settings
            phase = .failed(L("No therapy settings were provided."))
            return
        }
        manager.finishSetup(
            basalItems: settings.basalSchedule.items,
            maxBasal: settings.maxBasalRateUnitsPerHour,
            maxBolus: settings.maxBolusUnits,
            insulinType: insulinType
        ) { [weak self] result in
            switch result {
            case .success: self?.onDone()
            case let .failure(error): self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}
