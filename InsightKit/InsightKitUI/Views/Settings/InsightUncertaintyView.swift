import LoopKit
import LoopKitUI
import SwiftUI

final class InsightUncertaintyViewModel: ObservableObject, InsightStateObserver {
    @Published private(set) var state: InsightPumpManagerState
    @Published var isChecking = false
    @Published var message: String?

    private let manager: InsightPumpManager
    var onFinished: () -> Void = {}

    init(manager: InsightPumpManager) {
        self.manager = manager
        state = manager.state
        manager.addStateObserver(self, queue: .main)
    }

    deinit { manager.removeStateObserver(self) }

    func stateDidUpdate(_ state: InsightPumpManagerState, _: InsightPumpManagerState) {
        self.state = state
        if !state.isDeliveryUncertain { onFinished() }
    }

    var description: String {
        guard let pending = state.pendingCommand else { return "" }
        switch pending.kind {
        case .bolus: return L("a bolus of %@", InsightFormat.units(pending.units, digits: 2))
        case .setTBR: return L("a temp basal of %d%%", pending.percent ?? 0)
        case .cancelTBR: return L("cancelling the temp basal")
        case .suspend: return L("suspending insulin delivery")
        case .resume: return L("resuming insulin delivery")
        }
    }

    var isBolus: Bool { state.pendingCommand?.kind == .bolus }

    func check() {
        isChecking = true
        message = nil
        manager.checkUncertainCommand { outcome in
            self.isChecking = false
            switch outcome {
            case .unreachable: self.message = L("The bridge could not be reached. Check the connection and try again.")
            case .undecided: self
                .message = L("The pump data is not conclusive yet. Try again in a minute or check the pump display.")
            default: break
            }
        }
    }

    func resolve(delivered: Bool) {
        manager.forceResolvePendingCommand(delivered: delivered)
    }
}

struct InsightUncertaintyView: View {
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.guidanceColors) private var guidanceColors
    @ObservedObject var viewModel: InsightUncertaintyViewModel
    @State private var confirmDelivered = false
    @State private var confirmNotDelivered = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Insulin delivery uncertain"))
                        .font(Font.subheadline.weight(.bold))
                        .foregroundColor(guidanceColors.critical)
                    Text(L(
                        "The connection was interrupted while Trio was sending %@. Trio does not know whether the pump carried it out and will never send it again by itself.",
                        viewModel.description
                    ))
                        .font(Font.footnote.weight(.semibold))
                    Text(
                        L(
                            "Trio keeps counting a possibly delivered bolus as insulin on board, and gives no further insulin until this is resolved."
                        )
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section {
                Button { viewModel.check() } label: {
                    HStack {
                        Text(L("Check the pump again"))
                        Spacer()
                        if viewModel.isChecking { ActivityIndicator(isAnimating: .constant(true), style: .medium) }
                    }
                }
                .disabled(viewModel.isChecking)
                if let message = viewModel.message {
                    Text(message).font(.footnote).foregroundColor(.insightWarningText)
                }
            } header: {
                Text(L("Let Trio check"))
            } footer: {
                Text(L("Trio compares the pump status and history with the command."))
            }
            Section {
                Button { confirmNotDelivered = true } label: { Text(L("It was not delivered")) }
                Button { confirmDelivered = true } label: { Text(L("It was delivered")) }
            } header: {
                Text(L("Or decide yourself"))
            } footer: {
                Text(L("Only use these after checking the pump display and its history."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: Button(L("Close"), action: { dismiss() }))
        .actionSheet(isPresented: $confirmNotDelivered) {
            ActionSheet(
                title: Text(L("Confirm: not delivered")),
                message: Text(L("Trio will forget this command. Make sure the pump did not deliver it.")),
                buttons: [.destructive(Text(L("It was not delivered"))) { viewModel.resolve(delivered: false) }, .cancel()]
            )
        }
        .actionSheet(isPresented: $confirmDelivered) {
            ActionSheet(
                title: Text(L("Confirm: delivered")),
                message: Text(L("Trio will count the command as carried out.")),
                buttons: [.default(Text(L("It was delivered"))) { viewModel.resolve(delivered: true) }, .cancel()]
            )
        }
    }
}
