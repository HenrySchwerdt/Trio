import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

final class InsightHUDProvider: NSObject, HUDProvider {
    var managerIdentifier: String { pumpManager.managerIdentifier }

    private let pumpManager: InsightPumpManager
    private var reservoirView: InsightReservoirView?
    private let bluetoothProvider: BluetoothProvider
    private let colorPalette: LoopUIColorPalette

    var visible: Bool = true {
        didSet {
            if oldValue != visible, visible { hudDidAppear() }
        }
    }

    init(pumpManager: InsightPumpManager, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette) {
        self.pumpManager = pumpManager
        self.bluetoothProvider = bluetoothProvider
        self.colorPalette = colorPalette
        super.init()
        self.pumpManager.addStateObserver(self, queue: .main)
    }

    func createHUDView() -> BaseHUDView? {
        reservoirView = InsightReservoirView.instantiate()
        updateReservoirView()
        return reservoirView
    }

    var hudViewRawState: HUDProvider.HUDViewRawState {
        var rawValue: HUDProvider.HUDViewRawState = [:]
        rawValue["lastStatusDate"] = pumpManager.rawState["lastStatusDate"]
        rawValue["reservoirLevel"] = pumpManager.rawState["reservoirLevel"]
        return rawValue
    }

    func didTapOnHUDView(_: BaseHUDView, allowDebugFeatures _: Bool) -> HUDTapAction? { nil }

    private func hudDidAppear() {
        updateReservoirView()
        pumpManager.ensureCurrentPumpData { _ in
            DispatchQueue.main.async { self.updateReservoirView() }
        }
    }

    static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        guard let lastStatusDate = rawValue["lastStatusDate"] as? Date else { return nil }
        let view = InsightReservoirView.instantiate()
        view.update(level: rawValue["reservoirLevel"] as? Double, at: lastStatusDate)
        return view
    }

    private func updateReservoirView() {
        guard let reservoirView, let date = pumpManager.state.lastStatusDate else { return }
        let level = pumpManager.state.reservoirUnits
        DispatchQueue.main.async { reservoirView.update(level: level, at: date) }
    }
}

extension InsightHUDProvider: InsightStateObserver {
    func stateDidUpdate(_: InsightPumpManagerState, _: InsightPumpManagerState) {
        updateReservoirView()
    }
}
