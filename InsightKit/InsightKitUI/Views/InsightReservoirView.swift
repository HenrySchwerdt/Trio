import LoopKitUI
import UIKit

protocol InsightNibLoadable: AnyObject {
    static func nib() -> UINib
}

extension InsightNibLoadable {
    static func nib() -> UINib {
        UINib(nibName: String(NSStringFromClass(self).split(separator: ".").last ?? ""), bundle: Bundle(for: self))
    }
}

/// Reservoir level in the Trio HUD (same look as the other pump kits).
public final class InsightReservoirView: LevelHUDView, InsightNibLoadable {
    override public var orderPriority: HUDViewOrderPriority { 11 }

    @IBOutlet private var volumeLabel: UILabel!

    private var reservoirLevel: Double?
    private var lastUpdateDate: Date?

    class func instantiate() -> InsightReservoirView {
        nib().instantiate(withOwner: nil, options: nil)[0] as! InsightReservoirView
    }

    override public func awakeFromNib() {
        super.awakeFromNib()
        volumeLabel.isHidden = true
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func updateViews() {
        guard let reservoirLevel, let date = lastUpdateDate else {
            level = 0
            volumeLabel.isHidden = true
            return
        }
        level = reservoirLevel / InsightPumpSpec.reservoirCapacity
        let units = String(format: "%.0f", reservoirLevel)
        let time = timeFormatter.string(from: date)
        caption?.text = time
        volumeLabel.isHidden = false
        volumeLabel.text = String(
            format: LocalizedString("%@U", comment: "Format string for reservoir volume. (1: The localized volume)"),
            units
        )
        accessibilityValue = String(
            format: LocalizedString(
                "%@ units remaining at %@",
                comment: "Accessibility format string for (1: localized volume)(2: time)"
            ),
            units, time
        )
    }

    func update(level: Double?, at date: Date) {
        reservoirLevel = level
        lastUpdateDate = date
        updateViews()
    }
}
