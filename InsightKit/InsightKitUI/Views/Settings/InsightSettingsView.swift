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

    /// ONE confirmation for the whole screen. (Several `.actionSheet(isPresented:)` modifiers on the same view
    /// override each other in SwiftUI: only the last one ever appeared, so most buttons did nothing.)
    enum Confirmation: String, Identifiable {
        case suspend
        case resume
        case syncBasal
        case syncTime
        case repair
        case delete
        var id: String { rawValue }
    }

    @State private var confirmation: Confirmation?

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
                Button { confirmation = .repair } label: {
                    Text(L("Pair bridge again"))
                }
                Button { openURL(InsightSetup.bridgeURL) } label: {
                    Text(L("InsightBridge help"))
                }
                Button { confirmation = .delete } label: {
                    Text(L("Delete Pump")).foregroundColor(guidanceColors.critical)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: Button(L("Done"), action: { dismiss() }))
        .actionSheet(item: $confirmation) { sheet(for: $0) }
        .background(
            // The alert lives on its own view: an alert and an action sheet on the same view can override each other.
            Color.clear.alert(item: $viewModel.resultMessage) { message in
                Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text(L("OK"))))
            }
        )
    }

    private func requestConfirmation(_ sheet: Confirmation, action: InsightSettingsViewModel.Action, title: String) {
        if let reason = viewModel.blockedReason(for: action) {
            viewModel.showBlocked(title: title, reason: reason)
        } else {
            confirmation = sheet
        }
    }

    private func sheet(for confirmation: Confirmation) -> ActionSheet {
        switch confirmation {
        case .suspend:
            return ActionSheet(
                title: Text(L("Suspend insulin delivery?")),
                message: Text(L("The pump stops all insulin delivery, including basal, until you resume.")),
                buttons: [.destructive(Text(L("Suspend insulin"))) { viewModel.suspend() }, .cancel()]
            )
        case .resume:
            return ActionSheet(
                title: Text(L("Resume insulin delivery?")),
                buttons: [.default(Text(L("Resume insulin"))) { viewModel.resume() }, .cancel()]
            )
        case .syncBasal:
            return ActionSheet(
                title: Text(L("Write the basal profile to the pump?")),
                message: Text(L("Your current basal schedule is sent to the pump and read back to verify it.")),
                buttons: [.default(Text(L("Sync basal profile"))) { viewModel.syncBasalProfile() }, .cancel()]
            )
        case .syncTime:
            return ActionSheet(
                title: Text(L("Time Change Detected")),
                message: Text(
                    L("The time on your pump controls your scheduled basal. It will be set to the current time of this iPhone.")
                ),
                buttons: [
                    .default(Text(L("Yes, sync to current time"))) { viewModel.syncTime() },
                    .cancel(Text(L("No, keep pump as is")))
                ]
            )
        case .repair:
            return ActionSheet(
                title: Text(L("Pair the bridge again?")),
                message: Text(
                    L(
                        "Use this if the connection was refused or you replaced the bridge phone. Your pump settings stay as they are."
                    )
                ),
                buttons: [.default(Text(L("Pair bridge again"))) { viewModel.requestRepair() }, .cancel()]
            )
        case .delete:
            return ActionSheet(
                title: Text(L("Remove Pump")),
                message: Text(
                    L("Are you sure you want to stop using the Accu-Chek Insight? The pairing with the bridge is deleted.")
                ),
                buttons: [.destructive(Text(L("Delete Pump"))) { viewModel.requestDelete() }, .cancel()]
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
                    Button { viewModel.requestResolveUncertainty() } label: {
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

            if let reason = viewModel.loopBlockedReason {
                notice(L("Trio cannot dose with the Insight"), reason, color: guidanceColors.critical)
            }

            if viewModel.profileWasSimplified {
                notice(
                    L("Pump basal profile simplified"),
                    L(
                        "The Insight only stores basal rates that change on full hours. Each hour uses the lowest rate Trio has scheduled in that hour; temp basals still deliver what Trio asks for."
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
        title: String, systemImage: String, iconColor: Color, busy: Bool = false, safety: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Dimmed while another action runs; a tap is never swallowed (the view model explains why it cannot run).
        let visuallyDisabled = !safety && viewModel.busyAction != nil
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
        .onTapGesture { action() }
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
                    busy: viewModel.isBusy(.suspend) || viewModel.busyAction == .resume,
                    safety: !viewModel.isSuspended
                ) {
                    let action: InsightSettingsViewModel.Action = viewModel.isSuspended ? .resume : .suspend
                    // Resuming is blocked by an uncertain command (with an explanation); suspending never is.
                    if let reason = viewModel.blockedReason(for: action) {
                        viewModel.showBlocked(
                            title: viewModel.isSuspended ? L("Resume Delivery") : L("Suspend Delivery"),
                            reason: reason
                        )
                    } else {
                        confirmation = viewModel.isSuspended ? .resume : .suspend
                    }
                }
                if viewModel.isTempBasal {
                    actionCard(
                        title: L("Stop Temp Basal"), systemImage: "xmark.circle.fill", iconColor: Color.accentColor,
                        busy: viewModel.isBusy(.stopTempBasal), safety: true
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
        switch viewModel.linkStatus {
        case .connected: return .green
        case .pairing,
             .reconnecting: return .orange
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

            statusRow(L("Bridge"), viewModel.connectionTitle, bridgeColor)
            statusRow(
                L("Pump"),
                viewModel.pumpLinkTitle,
                viewModel.pumpLinkIsOK ? .green : (state.pumpLink == .connecting ? .orange : .red)
            )
            if let hint = viewModel.connectionHint {
                Text(hint).font(.footnote).foregroundColor(.secondary)
            }

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
            Button { requestConfirmation(.syncBasal, action: .syncBasal, title: L("Basal profile")) } label: {
                HStack {
                    Text(L("Sync basal profile"))
                    Spacer()
                    if viewModel.busyAction == .syncBasal { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                }
            }
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
            Button { requestConfirmation(.syncTime, action: .syncTime, title: L("Pump time")) } label: {
                HStack {
                    Text(L("Manually sync Pump time")).foregroundColor(.accentColor)
                    Spacer()
                    if viewModel.busyAction == .syncTime { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                }
            }
        } header: {
            Text(L("Pump time"))
        }
    }
}
