import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum InsightUIScreen {
    case intro
    case scan
    case pairing(DiscoveredBridge)
    case pumpCheck
    case finish
    case settings
    case repairScan
    case repairPairing(DiscoveredBridge)
    case uncertainty
}

final class InsightUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying,
    UINavigationControllerDelegate
{
    var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private let colorPalette: LoopUIColorPalette
    private let pumpManager: InsightPumpManager
    private let setupSettings: PumpManagerSetupSettings?
    private let allowedInsulinTypes: [InsulinType]
    private let allowDebugFeatures: Bool
    private let isSetup: Bool
    private let startAtUncertainty: Bool
    private var setupCompleted = false

    init(
        pumpManager: InsightPumpManager?,
        colorPalette: LoopUIColorPalette,
        setupSettings: PumpManagerSetupSettings?,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType],
        startAtUncertainty: Bool = false
    ) {
        isSetup = pumpManager == nil
        self.pumpManager = pumpManager ?? InsightPumpManager(state: InsightPumpManagerState())
        self.colorPalette = colorPalette
        self.setupSettings = setupSettings
        self.allowDebugFeatures = allowDebugFeatures
        self.allowedInsulinTypes = allowedInsulinTypes
        self.startAtUncertainty = startAtUncertainty
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        navigationBar.prefersLargeTitles = true // like the other pump kits
        let first: InsightUIScreen = startAtUncertainty ? .uncertainty :
            (isSetup || !pumpManager.isOnboarded ? .intro : .settings)
        let vc = viewController(for: first)
        vc.isModalInPresentation = false
        setViewControllers([vc], animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent, isSetup, !setupCompleted {
            pumpManager.cancelSetup()
        }
    }

    // MARK: helpers

    private func hosting<Content: View>(_ rootView: Content, title: String? = nil) -> UIViewController {
        let hosted = DismissibleHostingController(content: rootView, colorPalette: colorPalette)
        hosted.navigationItem.title = title
        hosted.navigationItem.largeTitleDisplayMode = .automatic
        return hosted
    }

    private func push(_ screen: InsightUIScreen) {
        let vc = viewController(for: screen)
        vc.isModalInPresentation = false
        pushViewController(vc, animated: true)
    }

    private func popToRoot() {
        popToRootViewController(animated: true)
    }

    private func finishSetup() {
        setupCompleted = true
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: pumpManager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func viewController(for screen: InsightUIScreen) -> UIViewController {
        switch screen {
        case .intro:
            return hosting(
                InsightSetupIntroView(next: { [weak self] in self?.push(.scan) }),
                title: L("Accu-Chek Insight")
            )

        case .scan:
            let model = InsightScanViewModel(manager: pumpManager)
            return hosting(
                InsightScanView(viewModel: model) { [weak self] device in self?.push(.pairing(device)) },
                title: L("Find the bridge")
            )

        case let .pairing(device):
            let model = InsightPairingViewModel(manager: pumpManager, device: device) { [weak self] in self?.push(.pumpCheck) }
            return hosting(
                InsightPairingView(viewModel: model) { [weak self] in self?.popViewController(animated: true) },
                title: L("Pair with the bridge")
            )

        case .pumpCheck:
            let model = InsightPumpCheckViewModel(manager: pumpManager)
            return hosting(
                InsightPumpCheckView(viewModel: model) { [weak self] in self?.push(.finish) },
                title: L("Check the pump")
            )

        case .finish:
            let model = InsightFinishViewModel(
                manager: pumpManager, settings: setupSettings, allowedInsulinTypes: allowedInsulinTypes
            ) { [weak self] in self?.finishSetup() }
            return hosting(InsightFinishView(viewModel: model), title: L("Sync settings"))

        case .settings:
            let model = InsightSettingsViewModel(manager: pumpManager, supportedInsulinTypes: allowedInsulinTypes)
            model.onRepair = { [weak self] in self?.push(.repairScan) }
            model.onResolveUncertainty = { [weak self] in self?.push(.uncertainty) }
            model.onDelete = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.pumpManager.delete()
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                }
            }
            return hosting(InsightSettingsView(viewModel: model), title: pumpManager.localizedTitle)

        case .repairScan:
            let model = InsightScanViewModel(manager: pumpManager)
            return hosting(
                InsightScanView(viewModel: model) { [weak self] device in self?.push(.repairPairing(device)) },
                title: L("Pair bridge again")
            )

        case let .repairPairing(device):
            let model = InsightPairingViewModel(manager: pumpManager, device: device) { [weak self] in self?.popToRoot() }
            return hosting(
                InsightPairingView(viewModel: model) { [weak self] in self?.popViewController(animated: true) },
                title: L("Pair bridge again")
            )

        case .uncertainty:
            let model = InsightUncertaintyViewModel(manager: pumpManager)
            model.onFinished = { [weak self] in
                guard let self else { return }
                if self.startAtUncertainty {
                    self.completionDelegate?.completionNotifyingDidComplete(self)
                } else {
                    self.popToRoot()
                }
            }
            return hosting(InsightUncertaintyView(viewModel: model), title: L("Uncertain delivery"))
        }
    }
}
