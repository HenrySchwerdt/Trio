import LoopKit
import LoopKitUI
import SwiftUI

extension InsightPumpManager: PumpManagerUI {
    public static func setupViewController(
        initialSettings settings: PumpManagerSetupSettings,
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        let coordinator = InsightUICoordinator(
            pumpManager: nil, colorPalette: colorPalette, setupSettings: settings,
            allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes
        )
        return .userInteractionRequired(coordinator)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        InsightUICoordinator(
            pumpManager: self, colorPalette: colorPalette, setupSettings: nil,
            allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        InsightUICoordinator(
            pumpManager: self, colorPalette: colorPalette, setupSettings: nil,
            allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: [], startAtUncertainty: true
        )
    }

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes _: [InsulinType]
    ) -> HUDProvider? {
        InsightHUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette)
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        InsightHUDProvider.createHUDView(rawValue: rawValue)
    }

    // MARK: images

    public static var onboardingImage: UIImage? { InsightImages.pump }

    public static var pickerImage: UIImage? { InsightImages.pump }

    public var smallImage: UIImage? { InsightImages.pump }

    // MARK: status indicator

    public var pumpStatusHighlight: PumpStatusHighlight? {
        let s = state
        if s.isDeliveryUncertain {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Delivery Uncertain",
                    comment: "Status highlight when a command has an unknown result"
                ),
                imageName: "exclamationmark.circle.fill", state: .critical
            )
        }
        if s.loopBlockedReason != nil {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Dosing Blocked",
                    comment: "Status highlight when Trio's last insulin command was refused"
                ),
                imageName: "exclamationmark.circle.fill", state: .critical
            )
        }
        if let alert = s.activePumpAlert, !alert.isSnoozed {
            let info = InsightAlertCatalog.info(for: alert)
            if info.severity == .error {
                return PumpStatusHighlight(
                    localizedMessage: info.title,
                    imageName: "exclamationmark.circle.fill",
                    state: .critical
                )
            }
        }
        if let reservoir = s.reservoirUnits, reservoir < 0.5 {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("No Insulin", comment: "Status highlight that a pump is out of insulin."),
                imageName: "exclamationmark.circle.fill", state: .critical
            )
        }
        if s.pumpLink == .notPaired {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("No Pump in Bridge", comment: "Status highlight when the bridge has no pump"),
                imageName: "exclamationmark.circle.fill", state: .critical
            )
        }
        if s.isSimulated {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("Simulated Pump", comment: "Status highlight for the simulated pump"),
                imageName: "exclamationmark.triangle.fill", state: .critical
            )
        }
        if s.isSuspended {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Insulin Suspended",
                    comment: "Status highlight that insulin delivery was suspended."
                ),
                imageName: "pause.circle.fill", state: .warning
            )
        }
        switch linkStatus {
        case .bridgeNotFound:
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Bridge Not Found",
                    comment: "Status highlight when the bridge is not in range"
                ),
                imageName: "exclamationmark.circle.fill", state: .warning
            )
        case let .reconnecting(since) where clock().timeIntervalSince(since) > 120:
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Bridge Reconnecting",
                    comment: "Status highlight while the bridge link is down"
                ),
                imageName: "exclamationmark.triangle.fill", state: .warning
            )
        default: break
        }
        if inSignalLoss {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Signal Loss",
                    comment: "Status highlight when communications with the pump haven't happened recently."
                ),
                imageName: "exclamationmark.circle.fill", state: .critical
            )
        }
        if s.pumpLink == .disconnected {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Pump Unreachable",
                    comment: "Status highlight when the bridge cannot reach the pump"
                ),
                imageName: "exclamationmark.circle.fill", state: .warning
            )
        }
        if let alert = s.activePumpAlert, !alert.isSnoozed {
            return PumpStatusHighlight(
                localizedMessage: InsightAlertCatalog.info(for: alert).title,
                imageName: "exclamationmark.triangle.fill", state: .warning
            )
        }
        if s.isOnboarded, s.basalSchedule != nil, !s.basalScheduleSynced {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Basal Not Confirmed",
                    comment: "Status highlight when the basal profile is not confirmed on the pump"
                ),
                imageName: "exclamationmark.triangle.fill", state: .warning
            )
        }
        return nil
    }

    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        guard let units = state.reservoirUnits else { return nil }
        let capacity = InsightPumpSpec.reservoirCapacity
        let progressState: DeviceLifecycleProgressState
        switch units {
        case ..<10: progressState = .critical
        case ..<20: progressState = .warning
        default: progressState = .normalPump
        }
        return PumpLifecycleProgress(percentComplete: min(max(1 - units / capacity, 0), 1), progressState: progressState)
    }

    public var pumpStatusBadge: DeviceStatusBadge? {
        needsTimeSync ? InsightStatusBadge.timeSyncNeeded : nil
    }
}

private enum InsightStatusBadge: DeviceStatusBadge {
    case timeSyncNeeded

    var image: UIImage? { UIImage(systemName: "clock.fill") }
    var state: DeviceStatusBadgeState { .warning }
}
