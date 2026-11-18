import LoopKit
import LoopKitUI
import SwiftUI

/// Localized string from this framework's `Localizable.xcstrings`.
func L(_ key: String) -> String {
    LocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: LocalizedString(key, comment: ""), arguments: args)
}

enum InsightImages {
    static var pump: UIImage? {
        UIImage(named: "insight_pump", in: Bundle.insightKit, compatibleWith: nil)
    }

    static func named(_ name: String) -> Image {
        Image(uiImage: UIImage(named: name, in: Bundle.insightKit, compatibleWith: nil) ?? UIImage())
    }
}

struct InsightPumpImageView: View {
    var height: CGFloat = 150

    var body: some View {
        HStack {
            Spacer()
            Group {
                if let image = InsightImages.pump {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "cross.vial.fill").resizable().scaledToFit().foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .frame(height: height)
            Spacer()
        }
        .accessibilityLabel(Text(L("Accu-Chek Insight pump")))
    }
}

/// Prominent warning shown when the bridge runs its simulated pump.
struct SimulatorBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(L("Simulated pump – no insulin is delivered"))
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(12)
        .background(Color.red)
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Setup page building blocks (same structure as DanaKitUI: inset grouped List + bottom button)

/// `VStack { List; ContinueButton }` exactly like the DanaKit/MedtrumKit setup screens, with the Cancel toolbar button.
struct InsightSetupScaffold<Content: View, Buttons: View>: View {
    @Environment(\.dismissAction) private var dismiss
    var showsCancel = true
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading) {
            List { content }
                .insetGroupedListStyle()
            buttons
        }
        .edgesIgnoringSafeArea(.bottom)
        .navigationBarHidden(false)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: dismiss) { Text(L("Cancel")) }
                }
            }
        }
    }
}

/// One or two stacked action buttons at the bottom (the layout of DanaKit's `ContinueButton`).
struct InsightActionButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .padding([.bottom, .horizontal])
            .padding(.vertical, 10)
    }
}

struct InsightContinueButton: View {
    var text = L("Continue")
    var loading = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        InsightActionButtons {
            Button(action: action) {
                if loading {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                } else {
                    Text(text)
                }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(loading || disabled)
        }
    }
}

/// Centered SF Symbol used as the illustration of a setup step.
struct InsightIllustration: View {
    let symbol: String

    var body: some View {
        HStack {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
                .padding(.vertical, 8)
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

func stepHeader(_ step: Int, _ total: Int) -> SectionHeader {
    SectionHeader(label: L("Step %d of %d", step, total))
}

/// A red/orange row used for errors and notices inside a list.
struct InsightNoticeRow: View {
    let message: String
    var critical = true
    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        Label {
            Text(message).font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundColor(critical ? guidanceColors.critical : Color.insightWarningText)
    }
}

// MARK: - Gauges

/// Reservoir drawing (mask + outline), same artwork and proportions as the other pump kits' `ReservoirView`.
struct InsightReservoirGauge: View {
    let units: Double?
    let capacity: Double
    let fillColor: Color

    private let maskHeightRatio = 0.887
    private let aspect = 28.0 / 44.0

    var body: some View {
        ZStack(alignment: .center) {
            GeometryReader { geometry in
                let height = min(geometry.size.height, geometry.size.width / aspect)
                let maskHeight = height * maskHeightRatio
                let level = max(0, min((units ?? 0) / capacity, 1))
                let fillHeight = maskHeight * level
                let cx = geometry.size.width / 2
                let cy = geometry.size.height / 2
                let maskOffset = (height - maskHeight) / 2
                Rectangle()
                    .fill(fillColor)
                    .mask(
                        InsightImages.named("reservoir_mask").renderingMode(.template).resizable().scaledToFit()
                            .frame(height: maskHeight).position(x: cx, y: cy + maskOffset)
                    )
                    .mask(
                        Rectangle()
                            .path(in: CGRect(
                                x: 0,
                                y: cy + maskHeight / 2 - fillHeight + maskOffset,
                                width: geometry.size.width,
                                height: fillHeight
                            ))
                    )
            }
            InsightImages.named("reservoir").renderingMode(.template).resizable().scaledToFit().foregroundColor(.secondary)
        }
    }
}

struct BatteryGauge: View {
    let percent: Double?

    private var symbol: String {
        guard let percent else { return "battery.0" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26))
            .foregroundColor((percent ?? 100) < 20 ? .red : .secondary)
    }
}

extension Color {
    /// Readable warning text on both light and dark backgrounds (the guidance yellow is too faint for text).
    static let insightWarningText = Color.orange
}

enum InsightFormat {
    static func units(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "–" }
        return String(format: "%.\(digits)f U", value)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f U/h", value)
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("Never") }
        if now.timeIntervalSince(date) < 45 { return L("Just now") }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
