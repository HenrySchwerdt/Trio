import Foundation
import LoopKit

/// Maps bridge/pump alerts (AndroidAPS `AlertType` names such as `E7_ELECTRONIC_ERROR`,
/// `WARNING_31`, `M21_PAUSE_MODE_ACTIVE`) to plain-language text and LoopKit alerts.
public struct InsightAlertInfo: Equatable {
    public enum Severity: Equatable { case error, warning, maintenance, reminder }

    public let severity: Severity
    /// Numeric part of the pump's alert code (e.g. 31 for W31), if parsable.
    public let code: Int?
    public let title: String
    public let explanation: String

    public var codeLabel: String? {
        guard let code else { return nil }
        switch severity {
        case .error: return "E\(code)"
        case .warning: return "W\(code)"
        case .maintenance: return "M\(code)"
        case .reminder: return "R\(code)"
        }
    }
}

public enum InsightAlertCatalog {
    static func parse(alertType: String) -> (Character?, Int?) {
        let upper = alertType.uppercased()
        let letter: Character?
        if upper.hasPrefix("ERROR") { letter = "E" }
        else if upper.hasPrefix("WARNING") { letter = "W" }
        else if upper.hasPrefix("MAINTENANCE") { letter = "M" }
        else if upper.hasPrefix("REMINDER") { letter = "R" }
        else if let first = upper.first, "EWMR".contains(first) { letter = first }
        else { letter = nil }

        let digits = upper.drop { !$0.isNumber }.prefix { $0.isNumber }
        return (letter, Int(digits))
    }

    public static func info(for alert: BridgeAlert) -> InsightAlertInfo {
        let (letter, code) = parse(alertType: alert.alertType)

        let severity: InsightAlertInfo.Severity
        switch alert.category {
        case .error: severity = .error
        case .warning: severity = .warning
        case .maintenance: severity = .maintenance
        case .reminder: severity = .reminder
        case .unknown:
            switch letter {
            case "E": severity = .error
            case "W": severity = .warning
            case "M": severity = .maintenance
            default: severity = .reminder
            }
        }

        if let known = known(severity: severity, code: code) {
            return InsightAlertInfo(severity: severity, code: code, title: known.0, explanation: known.1)
        }

        let title: String
        let explanation: String
        switch severity {
        case .error:
            title = LocalizedString("Pump error", comment: "Insight alert title")
            explanation = LocalizedString(
                "The pump reported an error and may have stopped delivering insulin. Check the pump display and follow its instructions.",
                comment: "Insight alert text"
            )
        case .warning:
            title = LocalizedString("Pump warning", comment: "Insight alert title")
            explanation = LocalizedString("The pump shows a warning. Check the pump display.", comment: "Insight alert text")
        case .maintenance:
            title = LocalizedString("Pump maintenance request", comment: "Insight alert title")
            explanation = LocalizedString("The pump asks for maintenance. Check the pump display.", comment: "Insight alert text")
        case .reminder:
            title = LocalizedString("Pump reminder", comment: "Insight alert title")
            explanation = LocalizedString("The pump shows a reminder.", comment: "Insight alert text")
        }
        return InsightAlertInfo(severity: severity, code: code, title: title, explanation: explanation)
    }

    private static func known(severity: InsightAlertInfo.Severity, code: Int?) -> (String, String)? {
        guard let code else { return nil }
        switch (severity, code) {
        case (.warning, 31):
            return (
                LocalizedString("Cartridge low", comment: "Insight alert title"),
                LocalizedString(
                    "The insulin cartridge is running low. Prepare a new cartridge.",
                    comment: "Insight alert text"
                )
            )
        case (.warning, 32):
            return (
                LocalizedString("Pump battery low", comment: "Insight alert title"),
                LocalizedString("The pump battery is low. Replace the battery soon.", comment: "Insight alert text")
            )
        case (.warning, 36):
            return (
                LocalizedString("Temporary basal ended", comment: "Insight alert title"),
                LocalizedString("A temporary basal rate on the pump has ended.", comment: "Insight alert text")
            )
        case (.warning, 38):
            return (
                LocalizedString("Bolus cancelled", comment: "Insight alert title"),
                LocalizedString(
                    "A bolus was cancelled. Only part of it may have been delivered.",
                    comment: "Insight alert text"
                )
            )
        case (.maintenance, 21):
            return (
                LocalizedString("Pump is paused", comment: "Insight alert title"),
                LocalizedString(
                    "The pump is paused and not delivering insulin. Resume delivery to continue.",
                    comment: "Insight alert text"
                )
            )
        case (.error, 6):
            return (
                LocalizedString("Mechanical error", comment: "Insight alert title"),
                LocalizedString(
                    "The pump reported a mechanical error and stopped delivering insulin. Follow the instructions on the pump display.",
                    comment: "Insight alert text"
                )
            )
        case (.error, 7):
            return (
                LocalizedString("Electronic error", comment: "Insight alert title"),
                LocalizedString(
                    "The pump reported an electronic error and stopped delivering insulin. Follow the instructions on the pump display.",
                    comment: "Insight alert text"
                )
            )
        default:
            return nil
        }
    }

    // MARK: LoopKit alert

    public static let managerIdentifier = "Insight"

    public static func alertIdentifier(for alert: BridgeAlert) -> Alert.AlertIdentifier {
        "insight.pump-alert.\(alert.alertType).\(alert.alertId)"
    }

    public static func loopAlert(for alert: BridgeAlert) -> Alert {
        let info = info(for: alert)
        var body = info.explanation
        if let label = info.codeLabel { body = "\(label): \(body)" }
        let content = Alert.Content(
            title: info.title, body: body,
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")
        )
        let level: Alert.InterruptionLevel
        switch info.severity {
        case .error: level = .critical
        case .warning: level = .timeSensitive
        case .maintenance,
             .reminder: level = .active
        }
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: alertIdentifier(for: alert)),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: level
        )
    }

    public static let unreadableHistoryAlertIdentifier = "insight.history-unreadable"
    public static let tbrMismatchAlertIdentifier = "insight.tbr-mismatch"
    public static let bolusMismatchAlertIdentifier = "insight.bolus-mismatch"
    public static let basalMismatchAlertIdentifier = "insight.basal-mismatch"
    public static let disconnectedAlertIdentifier = "insight.bridge-disconnected"
    public static let uncertainAlertIdentifier = "insight.delivery-uncertain"

    public static func bridgeDisconnectedAlert() -> Alert {
        let content = Alert.Content(
            title: LocalizedString("Pump not reachable", comment: "Alert title"),
            body: LocalizedString(
                "Trio has not been able to talk to the InsightBridge app for a while. Check that the Android phone is on, the app is running and Bluetooth is enabled.",
                comment: "Alert body"
            ),
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")
        )
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: disconnectedAlertIdentifier),
            foregroundContent: content, backgroundContent: content, trigger: .immediate, interruptionLevel: .timeSensitive
        )
    }

    private static func simpleAlert(_ identifier: String, title: String, body: String, level: Alert.InterruptionLevel) -> Alert {
        let content = Alert.Content(
            title: title, body: body, acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")
        )
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: identifier),
            foregroundContent: content, backgroundContent: content, trigger: .immediate, interruptionLevel: level
        )
    }

    public static func unreadableHistoryAlert() -> Alert {
        simpleAlert(
            unreadableHistoryAlertIdentifier,
            title: LocalizedString("Pump history unreadable", comment: "Alert title"),
            body: LocalizedString(
                "Trio could not read an entry of the pump history. Insulin that may have been delivered is counted. Check the pump history and update the InsightBridge app.",
                comment: "Alert body"
            ),
            level: .timeSensitive
        )
    }

    public static func tbrMismatchAlert(requested: Int, actual: Int) -> Alert {
        simpleAlert(
            tbrMismatchAlertIdentifier,
            title: LocalizedString("Temp basal differs from the request", comment: "Alert title"),
            body: String(
                format: LocalizedString(
                    "Trio asked for a temp basal of %d%% but the pump reports %d%%. The pump value is used.",
                    comment: "Alert body"
                ),
                requested,
                actual
            ),
            level: .timeSensitive
        )
    }

    public static func bolusMismatchAlert(requested: Double, actual: Double) -> Alert {
        simpleAlert(
            bolusMismatchAlertIdentifier,
            title: LocalizedString("Bolus differs from the request", comment: "Alert title"),
            body: String(
                format: LocalizedString(
                    "Trio asked for a bolus of %.2f U but the pump reports %.2f U. The pump value is used.",
                    comment: "Alert body"
                ),
                requested,
                actual
            ),
            level: .timeSensitive
        )
    }

    public static func basalMismatchAlert(pump: Double, local: Double) -> Alert {
        simpleAlert(
            basalMismatchAlertIdentifier,
            title: LocalizedString("Basal profile not confirmed", comment: "Alert title"),
            body: String(
                format: LocalizedString(
                    "The pump reports %.2f U/h but Trio expects %.2f U/h. Temp basals are paused until the basal profile is synced in the pump settings.",
                    comment: "Alert body"
                ),
                pump,
                local
            ),
            level: .timeSensitive
        )
    }
}
