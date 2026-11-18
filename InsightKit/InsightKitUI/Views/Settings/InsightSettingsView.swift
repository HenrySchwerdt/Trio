import LoopKit
import LoopKitUI
import SwiftUI

/// Settings screen. Structure, section names, fonts and colors follow DanaKit/MedtrumKit's settings:
/// header (image, delivery + insulin remaining), "Manage" action cards, "Sync", "Configuration",
/// "Pump information", "Pump time" and finally "Delete Pump" in red.
struct InsightSettingsView: View {
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.insulinTintColor) private var insulinTintColor
    @Environment(\.openURL) private var openURL

    @ObservedObject var viewModel: InsightSettingsViewModel

    @State private var showSuspendConfirm = false
    @State private var showResumeConfirm = false
    @State private var showSyncBasalConfirm = false
    @State private var showSyncTimeConfirm = false
    @State private var showRepairConfirm = false
    @State private var showDeleteConfirm = false

    private var state: InsightPumpManagerState { viewModel.state }

    var body: some View {
        List {
            headerSection
            manageSection
            syncSection
            configurationSection
            pumpInformationSection
            pumpTimeSection
            Section {
                Button { showRepairConfirm = true } label: {
                    Text(L("Pair bridge again"))
                }
                Button { openURL(InsightSetup.bridgeURL) } label: {
                    Text(L("InsightBridge help"))
                }
                Button { showDeleteConfirm = true } label: {
                    Text(L("Delete Pump")).foregroundColor(guidanceColors.critical)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: Button(L("Done"), action: { dismiss() }))
        .alert(item: $viewModel.resultMessage) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text(L("OK"))))
        }
        .actionSheet(isPresented: $showSuspendConfirm) {
            ActionSheet(
                title: Text(L("Suspend insulin delivery?")),
                message: Text(L("The pump stops all insulin delivery, including basal, until you resume.")),
                buttons: [.destructive(Text(L("Suspend insulin"))) { viewModel.suspend() }, .cancel()]
            )
        }
        .actionSheet(isPresented: $showResumeConfirm) {
            ActionSheet(
                title: Text(L("Resume insulin delivery?")),
                buttons: [.default(Text(L("Resume insulin"))) { viewModel.resume() }, .cancel()]
            )
        }
        .actionSheet(isPresented: $showSyncBasalConfirm) {
            ActionSheet(
                title: Text(L("Write the basal profile to the pump?")),
                message: Text(L("Your current basal schedule is sent to the pump and read back to verify it.")),
                buttons: [.default(Text(L("Sync basal profile"))) { viewModel.syncBasalProfile() }, .cancel()]
            )
        }
        .actionSheet(isPresented: $showSyncTimeConfirm) {
            ActionSheet(
                title: Text(L("Time Change Detected")),
                message: Text(
                    L("The time on your pump controls your scheduled basal. It will be set to the current time of this iPhone.")
                ),
                buttons: [
                    .default(Text(L("Yes, sync to current time"))) { viewModel.syncTime() },
                    .cancel(Text(L("No, keep pump as is")))
                ]
            )
        }
        .actionSheet(isPresented: $showRepairConfirm) {
            ActionSheet(
                title: Text(L("Pair the bridge again?")),
                message: Text(
                    L(
                        "Use this if the connection was refused or you replaced the bridge phone. Your pump settings stay as they are."
                    )
                ),
                buttons: [.default(Text(L("Pair bridge again"))) { viewModel.onRepair() }, .cancel()]
            )
        }
        .actionSheet(isPresented: $showDeleteConfirm) {
            ActionSheet(
                title: Text(L("Remove Pump")),
                message: Text(
                    L("Are you sure you want to stop using the Accu-Chek Insight? The pairing with the bridge is deleted.")
                ),
                buttons: [.destructive(Text(L("Delete Pump"))) { viewModel.onDelete() }, .cancel()]
            )
        }
    }

    // MARK: header (image, notices, delivery + reservoir)

    private func notice(_ title: String, _ message: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Font.subheadline.weight(.bold))
                .foregroundColor(color ?? .primary)
            Text(message)
                .font(Font.footnote.weight(.semibold))
        }
        .padding(.vertical, 8)
    }

    private var headerSection: some View {
        Section {
            if viewModel.isSimulated {
                SimulatorBanner().padding(.vertical, 4)
            }

            InsightPumpImageView(height: 150)

            HStack(alignment: .top) {
                deliveryStatus
                Spacer()
                reservoirStatus
            }
            .padding(.bottom, 5)

            if state.isDeliveryUncertain {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Insulin delivery uncertain"))
                        .font(Font.subheadline.weight(.bold))
                        .foregroundColor(guidanceColors.critical)
                    if let text = viewModel.pendingDescription {
                        Text(
                            L(
                                "Trio could not confirm the last command (%@). No further insulin is given until this is resolved.",
                                text
                            )
                        )
                        .font(Font.footnote.weight(.semibold))
                    }
                    Button { viewModel.onResolveUncertainty() } label: {
                        Text(L("Resolve uncertain delivery")).font(.title3).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 8)
            }

            if let alert = viewModel.activeAlert {
                notice(
                    alert.info.codeLabel.map { "\(alert.info.title) (\($0))" } ?? alert.info.title,
                    alert.info.explanation + " " + L("Confirm the alert on the pump or when Trio shows it as a notification."),
                    color: alert.info.severity == .error ? guidanceColors.critical : nil
                )
            }

            if viewModel.showPumpTimeSyncWarning {
                notice(
                    L("Time Change Detected"),
                    L(
                        "The time on your pump is different from the current time. Your pump’s time controls your scheduled basal. Scroll down to the Pump time section to review the difference and configure your pump."
                    )
                )
            }

            if viewModel.repairSuspected {
                notice(
                    L("Bridge connection"),
                    L("The bridge asked to be paired again. If this keeps happening, pair the bridge again.")
                )
            }
        }
    }

    private var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.basalSectionTitle)
                .foregroundColor(Color(UIColor.secondaryLabel))

            if state.isDeliveryUncertain {
                HStack(alignment: .center) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.critical)
                    Text(L("Delivery\nUncertain")).fontWeight(.bold).fixedSize()
                }
            } else if viewModel.isSuspended {
                HStack(alignment: .center) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text(L("Insulin\nSuspended")).fontWeight(.bold).fixedSize()
                }
            } else if let basalRate = viewModel.basalRateValue {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(String(format: "%.2f", basalRate))
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                        Text(L("U/hr")).foregroundColor(.secondary)
                    }
                    if let remaining = viewModel.tempBasalRemaining {
                        Text(remaining).foregroundColor(.secondary).font(.footnote)
                    }
                }
            } else {
                HStack(alignment: .center) {
                    Image(systemName: "x.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text(L("Unknown")).fontWeight(.bold).fixedSize()
                }
            }
        }
    }

    private func reservoirColor(_ level: Double) -> Color {
        if level > viewModel.reservoirLevelWarning { return insulinTintColor }
        if level > 0 { return guidanceColors.warning }
        return guidanceColors.critical
    }

    private var reservoirStatus: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(L("Insulin Remaining"))
                .foregroundColor(Color(UIColor.secondaryLabel))
            if let level = state.reservoirUnits {
                HStack(alignment: .center, spacing: 5) {
                    InsightReservoirGauge(units: level, capacity: viewModel.capacity, fillColor: reservoirColor(level))
                        .frame(width: 19, height: 26)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", level))
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                        Text(L("U")).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("–").font(.system(size: 28)).fontWeight(.heavy)
            }
            HStack(spacing: 6) {
                BatteryGauge(percent: state.batteryPercent).font(.system(size: 18))
                Text(state.batteryPercent.map { String(format: "%.0f %%", $0) } ?? "–")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Manage (action cards, like DanaKit)

    @ViewBuilder private func actionCard(
        title: String, systemImage: String, iconColor: Color, disabled: Bool = false, busy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let visuallyDisabled = disabled || viewModel.busyAction != nil
        VStack(spacing: 8) {
            if busy {
                ActivityIndicator(isAnimating: .constant(true), style: .medium).frame(height: 28)
            } else {
                Image(systemName: systemImage).font(.system(size: 28)).foregroundColor(iconColor)
            }
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(UIColor.secondarySystemGroupedBackground)))
        .opacity(visuallyDisabled ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { if !visuallyDisabled { action() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }

    private var manageSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                actionCard(
                    title: viewModel.isSuspended ? L("Resume Delivery") : L("Suspend Delivery"),
                    systemImage: viewModel.isSuspended ? "play.circle.fill" : "pause.circle.fill",
                    iconColor: viewModel.isSuspended ? Color.accentColor : guidanceColors.warning,
                    disabled: state.isDeliveryUncertain,
                    busy: viewModel.busyAction == .suspend || viewModel.busyAction == .resume
                ) {
                    if viewModel.isSuspended { showResumeConfirm = true } else { showSuspendConfirm = true }
                }
                if viewModel.isTempBasal {
                    actionCard(
                        title: L("Stop Temp Basal"), systemImage: "xmark.circle.fill", iconColor: Color.accentColor,
                        disabled: state.isDeliveryUncertain, busy: viewModel.busyAction == .stopTempBasal
                    ) {
                        viewModel.stopTempBasal()
                    }
                } else {
                    actionCard(
                        title: L("Sync pump data"), systemImage: "arrow.clockwise.circle.fill", iconColor: Color.accentColor,
                        busy: viewModel.busyAction == .refresh
                    ) {
                        viewModel.refresh()
                    }
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text(L("Manage"))
        }
    }

    // MARK: Sync

    private func statusRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).foregroundColor(Color.primary)
            Spacer()
            HStack(spacing: 10) {
                Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
                Circle().fill(color).frame(width: 10, height: 10)
            }
        }
    }

    private var bridgeColor: Color {
        switch viewModel.connection {
        case .ready: return .green
        case .handshaking,
             .linkConnecting,
             .pairing: return .orange
        default: return .red
        }
    }

    private var syncSection: some View {
        Section {
            Button { viewModel.refresh() } label: {
                HStack {
                    Text(L("Sync pump data"))
                    Spacer()
                    if viewModel.busyAction == .refresh { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                }
            }
            .disabled(viewModel.busyAction != nil)

            statusRow(L("Bridge"), viewModel.connectionTitle, bridgeColor)
            statusRow(
                L("Pump"),
                viewModel.pumpLinkTitle,
                viewModel.pumpLinkIsOK ? .green : (state.pumpLink == .connecting ? .orange : .red)
            )

            HStack {
                Text(L("Last sync")).foregroundColor(Color.primary)
                Spacer()
                Text(viewModel.lastCommunication).foregroundColor(.secondary)
            }
            HStack {
                Text(L("Pump last read")).foregroundColor(Color.primary)
                Spacer()
                Text(viewModel.lastPumpRead).foregroundColor(.secondary)
            }
            if case .bluetoothUnavailable = viewModel.connection {
                Text(L("Turn Bluetooth on and allow Trio to use it.")).font(.footnote).foregroundColor(.insightWarningText)
            }
        } header: {
            Text(L("Sync"))
        }
    }

    // MARK: Configuration

    private var configurationSection: some View {
        Section {
            HStack {
                Text(L("Insulin Type")).foregroundColor(Color.primary)
                Spacer()
                Text(state.insulinType?.brandName ?? "–").foregroundColor(.secondary)
            }
            HStack {
                Text(L("Basal profile")).foregroundColor(Color.primary)
                Spacer()
                Text(viewModel.scheduleStatus)
                    .foregroundColor(state.basalSchedule != nil && !state.basalScheduleSynced ? .insightWarningText : .secondary)
            }
            Button { showSyncBasalConfirm = true } label: {
                HStack {
                    Text(L("Sync basal profile"))
                    Spacer()
                    if viewModel.busyAction == .syncBasal { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                }
            }
            .disabled(viewModel.busyAction != nil || state.isDeliveryUncertain)
        } header: {
            Text(L("Configuration"))
        }
    }

    // MARK: Pump information

    private func infoRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundColor(Color.primary)
            Spacer()
            Text(value ?? "–").foregroundColor(.secondary)
        }
    }

    private var pumpInformationSection: some View {
        Section {
            infoRow(L("Pump serial number"), state.pumpSerial)
            infoRow(L("Firmware version"), state.pumpFirmware)
            infoRow(L("Bridge name"), state.bridgeName)
            infoRow(L("Bridge ID"), state.bridgeId)
            infoRow(L("Bridge version"), state.bridgeVersion)
            infoRow(L("Protocol version"), String(BridgeProtocol.version))
            infoRow(L("Battery level"), state.batteryPercent.map { String(format: "%.0f%%", $0) })
        } header: {
            Text(L("Pump information"))
        }
    }

    // MARK: Pump time

    private var pumpTimeSection: some View {
        Section {
            HStack {
                Text(L("Pump time")).foregroundColor(Color.primary)
                Spacer()
                if viewModel.showPumpTimeSyncWarning {
                    Image(systemName: "clock.fill").foregroundColor(guidanceColors.warning)
                }
                Text(viewModel.pumpTimeText)
                    .foregroundColor(viewModel.showPumpTimeSyncWarning ? .insightWarningText : .secondary)
            }
            HStack {
                Text(L("Checked at")).foregroundColor(Color.primary)
                Spacer()
                Text(viewModel.checkedAtText).foregroundColor(.secondary)
            }
            Button { showSyncTimeConfirm = true } label: {
                HStack {
                    Text(L("Manually sync Pump time")).foregroundColor(.accentColor)
                    Spacer()
                    if viewModel.busyAction == .syncTime { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                }
            }
            .disabled(viewModel.busyAction != nil)
        } header: {
            Text(L("Pump time"))
        }
    }
}
