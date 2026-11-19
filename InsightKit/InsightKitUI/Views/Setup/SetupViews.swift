import LoopKit
import LoopKitUI
import SwiftUI

enum InsightSetup {
    static let totalSteps = 5
    static let bridgeURL = URL(string: "https://github.com/HenrySchwerdt/InsightBridge")!
}

// MARK: - Step 1: intro

struct InsightSetupIntroView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.appName) private var appName
    let next: () -> Void

    var body: some View {
        InsightSetupScaffold {
            Section(header: stepHeader(1, InsightSetup.totalSteps)) {
                InsightPumpImageView(height: 110)
                Text(
                    L(
                        "The Insight pump cannot talk to an iPhone directly. Trio controls it through a small Android helper app called InsightBridge that stays connected to the pump."
                    )
                )
            }
            Section(header: SectionHeader(label: L("Before you start"))) {
                InstructionList(instructions: [
                    (
                        L("An Android phone with InsightBridge"),
                        L("Install and open the InsightBridge app on an Android phone that stays near you.")
                    ),
                    (
                        L("The pump is already paired in InsightBridge"),
                        L("Pair your Insight pump in the InsightBridge app first. Trio only talks to the bridge.")
                    ),
                    (L("Bluetooth is on"), L("Bluetooth must be on for both phones. Keep them close during setup."))
                ])
                    .padding(.vertical, 4)
                Button { openURL(InsightSetup.bridgeURL) } label: {
                    HStack {
                        Text(L("Get InsightBridge and read the instructions"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
        } buttons: {
            InsightContinueButton(text: L("I'm ready"), action: next)
        }
    }
}

// MARK: - Step 2: scan

struct InsightScanView: View {
    @ObservedObject var viewModel: InsightScanViewModel
    let select: (DiscoveredBridge) -> Void

    var body: some View {
        InsightSetupScaffold {
            Section(header: stepHeader(2, InsightSetup.totalSteps)) {
                InsightIllustration(symbol: "magnifyingglass")
                Text(L("Open InsightBridge on the Android phone, then tap your bridge below."))
                if let error = viewModel.errorMessage { InsightNoticeRow(message: error) }
            }

            Section(header: SectionHeader(label: viewModel.devices.isEmpty ? L("Scanning") : L("Bridges found"))) {
                if viewModel.devices.isEmpty {
                    HStack(spacing: 10) {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        Text(L("Searching for InsightBridge…")).foregroundColor(.secondary)
                    }
                } else {
                    ForEach(viewModel.devices) { device in
                        Button { select(device) } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.showTroubleshooting && viewModel.devices.isEmpty {
                Section(header: SectionHeader(label: L("Bridge not found?"))) {
                    BulletedListView {
                        L("Is the InsightBridge app open on the Android phone? It only advertises while it is running.")
                        L("Is Bluetooth turned on on both phones?")
                        L("Move the phones closer together.")
                        L("Make sure Trio is allowed to use Bluetooth in the iOS Settings.")
                    }
                    .padding(.vertical, 4)
                }
            }
        } buttons: {
            EmptyView()
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

// MARK: - Step 3: pairing

struct InsightPairingView: View {
    @ObservedObject var viewModel: InsightPairingViewModel
    let back: () -> Void

    var body: some View {
        InsightSetupScaffold(showsCancel: false) {
            content
        } buttons: {
            buttons
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { viewModel.start() }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .connecting:
            Section(header: stepHeader(3, InsightSetup.totalSteps)) {
                InsightIllustration(symbol: "lock.shield")
                HStack(spacing: 10) {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    Text(L("Connecting to %@…", viewModel.device.name)).foregroundColor(.secondary)
                }
            }
            Section(header: SectionHeader(label: L("On the Android phone"))) {
                Text(L("In InsightBridge tap \"Pair with iPhone\". The bridge only accepts pairing for two minutes."))
            }

        case let .confirmCode(code):
            Section(header: stepHeader(3, InsightSetup.totalSteps)) {
                Text(L("Is this the same code as in InsightBridge?"))
                HStack {
                    Spacer()
                    Text(code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.vertical, 8)
                        .accessibilityLabel(Text(code.map(String.init).joined(separator: " ")))
                    Spacer()
                }
                DescriptiveText(
                    label: L(
                        "Only continue if both phones show exactly this code. If they differ, tap Cancel – somebody else may be trying to connect."
                    )
                )
            }

        case .waitingForBridgeConfirmation:
            Section(header: stepHeader(3, InsightSetup.totalSteps)) {
                InsightIllustration(symbol: "lock.shield")
                Text(L("Now confirm the code on the Android phone."))
                HStack(spacing: 10) {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                    Text(L("Waiting for InsightBridge…")).foregroundColor(.secondary)
                }
            }

        case .done:
            Section(header: stepHeader(3, InsightSetup.totalSteps)) {
                InsightIllustration(symbol: "checkmark.circle.fill")
                Text(L("Paired with %@", viewModel.device.name))
            }

        case let .failed(failure, message):
            Section(header: stepHeader(3, InsightSetup.totalSteps)) {
                InsightNoticeRow(message: message)
            }
            switch failure {
            case .notInPairingMode:
                Section(header: SectionHeader(label: L("What to do"))) {
                    BulletedListView {
                        L("Open InsightBridge on the Android phone.")
                        L("Tap \"Pair with iPhone\" and then try again within two minutes.")
                    }
                    .padding(.vertical, 4)
                }
            case .rejected:
                Section(header: SectionHeader(label: L("Code mismatch or cancelled"))) {
                    BulletedListView {
                        L("Pairing was cancelled on one of the phones.")
                        L("Start again; both phones must show the same code.")
                    }
                    .padding(.vertical, 4)
                }
            case .timeout:
                Section(header: SectionHeader(label: L("No answer"))) {
                    BulletedListView {
                        L("Is InsightBridge open and in range?")
                        L("Tap \"Pair with iPhone\" in the bridge app, then try again.")
                    }
                    .padding(.vertical, 4)
                }
            case .bluetooth:
                Section(header: SectionHeader(label: L("Bluetooth"))) {
                    Text(L("Turn Bluetooth on and allow Trio to use it."))
                }
            case .other:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch viewModel.phase {
        case .connecting,
             .waitingForBridgeConfirmation:
            InsightActionButtons {
                Button { viewModel.cancel()
                    back() } label: { Text(L("Cancel")) }
                    .buttonStyle(ActionButtonStyle(.secondary))
            }
        case .confirmCode:
            InsightActionButtons {
                Button { viewModel.codesMatch() } label: { Text(L("Codes match")) }.buttonStyle(ActionButtonStyle())
                Button { viewModel.codesDoNotMatch()
                    back() } label: { Text(L("Cancel")) }
                    .buttonStyle(ActionButtonStyle(.destructive))
            }
        case .done:
            InsightContinueButton { viewModel.finish() }
        case .failed:
            InsightActionButtons {
                Button { viewModel.start() } label: { Text(L("Try again")) }.buttonStyle(ActionButtonStyle())
                Button { back() } label: { Text(L("Back")) }.buttonStyle(ActionButtonStyle(.secondary))
            }
        }
    }
}

// MARK: - Step 4: pump check

struct InsightPumpCheckView: View {
    @ObservedObject var viewModel: InsightPumpCheckViewModel
    let next: () -> Void
    @Environment(\.openURL) private var openURL

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.primary)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    var body: some View {
        InsightSetupScaffold(showsCancel: true) {
            switch viewModel.phase {
            case .checking:
                Section(header: stepHeader(4, InsightSetup.totalSteps)) {
                    InsightIllustration(symbol: "cross.vial")
                    HStack(spacing: 10) {
                        ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        Text(L("Reading the pump through the bridge…")).foregroundColor(.secondary)
                    }
                }
            case let .success(summary):
                Section(header: stepHeader(4, InsightSetup.totalSteps)) {
                    if summary.isSimulated { SimulatorBanner() }
                    row(L("Serial number"), summary.serial ?? "–")
                    row(L("Firmware"), summary.firmware ?? "–")
                    row(L("Insulin in reservoir"), InsightFormat.units(summary.reservoir))
                    row(L("Battery"), summary.battery.map { String(format: "%.0f %%", $0) } ?? "–")
                }
            case let .failed(message, noPump):
                Section(header: stepHeader(4, InsightSetup.totalSteps)) {
                    InsightNoticeRow(message: message)
                }
                Section(header: SectionHeader(label: noPump ? L("The bridge has no pump") : L("Check the connection"))) {
                    if noPump {
                        BulletedListView {
                            L("Open InsightBridge and pair your Insight pump there first.")
                            L("Then come back and tap Try again.")
                        }
                        .padding(.vertical, 4)
                    } else {
                        BulletedListView {
                            L("InsightBridge must be running and connected to the pump.")
                            L("Keep the Android phone close to the pump and to this iPhone.")
                        }
                        .padding(.vertical, 4)
                    }
                    Button { openURL(InsightSetup.bridgeURL) } label: {
                        HStack {
                            Text(L("InsightBridge instructions"))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
        } buttons: {
            switch viewModel.phase {
            case .checking:
                EmptyView()
            case .success:
                InsightContinueButton(action: next)
            case .failed:
                InsightContinueButton(text: L("Try again")) { viewModel.check() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { viewModel.check() }
    }
}

// MARK: - Step 5: sync settings

struct InsightFinishView: View {
    @ObservedObject var viewModel: InsightFinishViewModel

    var body: some View {
        InsightSetupScaffold {
            Section(header: stepHeader(5, InsightSetup.totalSteps)) {
                if viewModel.isSimulated { SimulatorBanner() }
                Text(L("Trio now sets the pump clock and writes your basal schedule to the pump."))
                Label(L("Set pump date, time and time zone"), systemImage: "clock")
                Label(viewModel.scheduleSummary, systemImage: "chart.bar.xaxis")
                Label(L("Apply your maximum bolus and basal limits"), systemImage: "gauge.with.dots.needle.33percent")
                DescriptiveText(
                    label: L(
                        "The Insight changes basal only on full hours. A schedule with other start times is converted: each hour uses the lowest rate scheduled in it, and Trio tells you."
                    )
                )
            }

            if viewModel.allowedInsulinTypes.count > 1 {
                Section(header: SectionHeader(label: L("Insulin type"))) {
                    ForEach(viewModel.allowedInsulinTypes, id: \.self) { type in
                        CheckmarkListItem(
                            title: Text(type.brandName),
                            description: Text(type.title),
                            isSelected: Binding(
                                get: { viewModel.insulinType == type },
                                set: { if $0 { viewModel.insulinType = type } }
                            )
                        )
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }

            if case let .failed(message) = viewModel.phase {
                Section { InsightNoticeRow(message: message) }
            }
        } buttons: {
            InsightContinueButton(
                text: viewModel.phase == .syncing ? L("Syncing…") : L("Sync and finish"),
                loading: viewModel.phase == .syncing
            ) { viewModel.sync() }
        }
        .navigationBarBackButtonHidden(true)
    }
}
