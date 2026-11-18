@testable import InsightKit
import LoopKit
import LoopKitUI
import SwiftUI
import XCTest

/// Instantiates and lays out every screen once to catch crashes (missing images/environment).
/// (Offscreen rendering is blank without a host app, so this is not a visual check.)
final class UISmokeTests: XCTestCase {
    private let size = CGSize(width: 390, height: 844)

    @MainActor private func render<V: View>(_: String, dark: Bool = false, height: CGFloat? = nil, _ view: V) throws {
        let hosting = DismissibleHostingController(content: NavigationView { view }.navigationViewStyle(.stack))
        let frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: height ?? size.height))
        let window = UIWindow(frame: frame)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.view.layoutIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    private func harness(_ configure: (inout InsightPumpManagerState) -> Void = { _ in }) -> ManagerHarness {
        ManagerHarness { state in
            state.pumpFirmware = "3.1.2"
            state.bridgeVersion = "0.4.0"
            state.batteryPercent = 72
            state.reservoirUnits = 118
            state.lastBridgeContact = Date().addingTimeInterval(-90)
            state.lastPumpReadDate = Date().addingTimeInterval(-200)
            state.pumpLink = .connected
            configure(&state)
        }
    }

    @MainActor func testSetupScreens() throws {
        let h = harness { $0.isOnboarded = false }
        try render("01-intro", InsightSetupIntroView(next: {}))

        let scan = InsightScanViewModel(manager: h.manager)
        try render("02-scan-searching", InsightScanView(viewModel: scan, select: { _ in }))
        scan.devices = [
            DiscoveredBridge(id: UUID(), name: "InsightBridge-A1B2", rssi: -52, lastSeen: Date()),
            DiscoveredBridge(id: UUID(), name: "InsightBridge-77C0", rssi: -88, lastSeen: Date())
        ]
        try render("02-scan-found", InsightScanView(viewModel: scan, select: { _ in }))
        scan.devices = []
        scan.showTroubleshooting = true
        try render("02-scan-help", InsightScanView(viewModel: scan, select: { _ in }))

        let device = DiscoveredBridge(id: UUID(), name: "InsightBridge-A1B2", rssi: -50, lastSeen: Date())
        let pairing = InsightPairingViewModel(manager: h.manager, device: device, onDone: {})
        pairing.phase = .confirmCode("481 902".replacingOccurrences(of: " ", with: ""))
        try render("03-pair-code", InsightPairingView(viewModel: pairing, back: {}))
        pairing.phase = .waitingForBridgeConfirmation
        try render("03-pair-waiting", InsightPairingView(viewModel: pairing, back: {}))
        pairing.phase = .failed(.notInPairingMode, BridgeError.pairingRejected("notInPairingMode").localizedDescription)
        try render("03-pair-failed", InsightPairingView(viewModel: pairing, back: {}))

        let check = InsightPumpCheckViewModel(manager: h.manager)
        check.phase = .success(.init(serial: "SIMULATOR", firmware: "sim", reservoir: 160, battery: 90, isSimulated: true))
        try render("04-check-ok-sim", InsightPumpCheckView(viewModel: check, next: {}))
        check.phase = .failed(
            BridgeError.remote(BridgeRemoteError(code: .notPaired, message: "", uncertain: false)).localizedDescription,
            noPump: true
        )
        try render("04-check-nopump", InsightPumpCheckView(viewModel: check, next: {}))

        let finish = InsightFinishViewModel(
            manager: h.manager,
            settings: nil,
            allowedInsulinTypes: [.novolog, .humalog],
            onDone: {}
        )
        try render("05-finish", InsightFinishView(viewModel: finish))
    }

    @MainActor func testSettingsScreens() throws {
        let normal = harness()
        let model = InsightSettingsViewModel(manager: normal.manager, supportedInsulinTypes: [.novolog])
        try render("10-settings-normal", height: 1500, InsightSettingsView(viewModel: model))
        try render("10-settings-normal-dark", dark: true, height: 1500, InsightSettingsView(viewModel: model))

        let busy = harness {
            $0.isSimulated = true
            $0.pumpSerial = "SIMULATOR"
            $0.operatingMode = .stopped
            $0.suspendedSince = Date().addingTimeInterval(-600)
            $0.pumpLink = .disconnected
            $0.reservoirUnits = 12
            $0.batteryPercent = 15
            $0.pumpTimeDriftSeconds = 400
            $0.basalScheduleSynced = false
            $0.activePumpAlert = BridgeAlert(alertId: 3, alertType: "W31_CARTRIDGE_LOW", category: .warning)
            $0.pendingCommand = PendingCommand(
                kind: .bolus,
                requestId: "r",
                sentDate: Date(),
                baselineSequence: 1,
                units: 1.5,
                percent: nil,
                durationMinutes: nil,
                scheduledRate: nil,
                decisionId: nil,
                automatic: true,
                insulinType: nil,
                isUncertain: true
            )
        }
        let busyModel = InsightSettingsViewModel(manager: busy.manager, supportedInsulinTypes: [.novolog])
        try render("11-settings-problems", height: 1900, InsightSettingsView(viewModel: busyModel))

        let tbr = harness {
            $0.tempBasals = [ActiveTempBasal(
                percent: 150,
                durationMinutes: 30,
                start: Date().addingTimeInterval(-300),
                scheduledRate: 1.0,
                effectiveRate: 1.5,
                decisionId: nil,
                automatic: true,
                endedAt: nil
            )]
            $0.bolus = UnfinalizedBolus(
                requestId: "r",
                units: 2.0,
                startDate: Date().addingTimeInterval(-20),
                bolusId: 1,
                decisionId: nil,
                automatic: false,
                insulinType: nil,
                deliveredUnits: 0.8,
                phase: .inProgress,
                endDate: nil,
                programmedOnPump: false
            )
        }
        try render(
            "12-settings-tbr-bolus",
            height: 1500,
            InsightSettingsView(viewModel: InsightSettingsViewModel(manager: tbr.manager, supportedInsulinTypes: [.novolog]))
        )

        let uncertain = InsightUncertaintyViewModel(manager: busy.manager)
        try render("13-uncertainty", InsightUncertaintyView(viewModel: uncertain))
    }

    @MainActor func testHudViewAndPumpImageRender() throws {
        let view = InsightReservoirView.instantiate()
        view.update(level: 118, at: Date())
        XCTAssertEqual(view.accessibilityValue?.contains("118"), true)
        XCTAssertNotNil(InsightImages.pump, "pump picker image is in the framework bundle")
        XCTAssertNotNil(InsightPumpManager.onboardingImage)
        XCTAssertNotNil(InsightPumpManager.pickerImage)
        XCTAssertNotNil(UIImage(named: "reservoir", in: Bundle.insightKit, compatibleWith: nil))
        XCTAssertNotNil(UIImage(named: "reservoir_mask", in: Bundle.insightKit, compatibleWith: nil))
    }

    func testStatusHighlights() {
        func highlight(_ configure: (inout InsightPumpManagerState) -> Void) -> PumpStatusHighlight? {
            harness(configure).manager.pumpStatusHighlight
        }
        XCTAssertNil(highlight { _ in })
        XCTAssertEqual(highlight { $0.reservoirUnits = 0 }?.state, .critical)
        XCTAssertEqual(highlight { $0.operatingMode = .stopped }?.localizedMessage, "Insulin Suspended")
        XCTAssertEqual(highlight { $0.isSimulated = true }?.localizedMessage, "Simulated Pump")
        XCTAssertEqual(highlight { $0.pumpLink = .notPaired }?.localizedMessage, "No Pump in Bridge")
        XCTAssertEqual(highlight {
            $0.pendingCommand = PendingCommand(
                kind: .suspend,
                requestId: "r",
                sentDate: Date(),
                baselineSequence: nil,
                units: nil,
                percent: nil,
                durationMinutes: nil,
                scheduledRate: nil,
                decisionId: nil,
                automatic: false,
                insulinType: nil,
                isUncertain: true
            )
        }?.localizedMessage, "Delivery Uncertain")
        XCTAssertEqual(
            highlight { $0.activePumpAlert = BridgeAlert(alertId: 1, alertType: "E7_ELECTRONIC_ERROR", category: .error) }?.state,
            .critical
        )
        XCTAssertEqual(highlight { $0.pumpLink = .disconnected }?.state, .warning)
        XCTAssertEqual(highlight { $0.basalScheduleSynced = false }?.localizedMessage, "Basal Not Confirmed")
        XCTAssertEqual(highlight { $0.lastBridgeContact = Date().addingTimeInterval(-3600)
            $0.lastPumpReadDate = Date().addingTimeInterval(-3600)
            $0.lastStatusDate = Date().addingTimeInterval(-3600) }?.localizedMessage, "Signal Loss")
    }

    func testLifecycleProgressAndBadge() {
        let h = harness { $0.reservoirUnits = 50 }
        let progress = h.manager.pumpLifecycleProgress
        XCTAssertEqual(progress?.progressState, .normalPump)
        XCTAssertEqual(progress?.percentComplete ?? 0, 1 - 50 / InsightPumpSpec.reservoirCapacity, accuracy: 1E-9)
        XCTAssertEqual(harness { $0.reservoirUnits = 15 }.manager.pumpLifecycleProgress?.progressState, .warning)
        XCTAssertEqual(harness { $0.reservoirUnits = 5 }.manager.pumpLifecycleProgress?.progressState, .critical)
        XCTAssertNil(harness().manager.pumpStatusBadge)
        XCTAssertNotNil(harness { $0.pumpTimeDriftSeconds = 300 }.manager.pumpStatusBadge)
    }

    func testGermanLocalizationIsComplete() throws {
        let path = try XCTUnwrap(
            Bundle.insightKit
                .path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "de")
        )
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertGreaterThan(table.count, 200)
        XCTAssertEqual(table["Suspend insulin"], "Insulin pausieren")
        XCTAssertEqual(table["Simulated pump – no insulin is delivered"], "Simulierte Pumpe – es wird kein Insulin abgegeben")
        let en = try XCTUnwrap(
            Bundle.insightKit
                .path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en")
        )
        XCTAssertEqual((NSDictionary(contentsOfFile: en) as? [String: String])?.count, table.count)
    }
}
