import Foundation
import os.log

/// Localization helper bound to this framework's bundle (Localizable.xcstrings).
func LocalizedString(_ key: String, comment: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: Bundle(for: InsightBundleToken.self), value: key, comment: comment)
}

final class InsightBundleToken {}

public extension Bundle {
    /// The bundle containing InsightKit's resources (asset catalog, strings).
    static var insightKit: Bundle { Bundle(for: InsightBundleToken.self) }
}

/// os.Logger wrapper. Never pass keys, nonces or ciphertext to it.
struct InsightLog {
    static let subsystem = "org.nightscout.InsightKit"
    private let logger: Logger

    init(category: String) {
        logger = Logger(subsystem: InsightLog.subsystem, category: category)
    }

    func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var idx = 0
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48 ... 57: return c - 48
            case 97 ... 102: return c - 87
            case 65 ... 70: return c - 55
            default: return nil
            }
        }
        while idx < chars.count {
            guard let hi = nibble(chars[idx]), let lo = nibble(chars[idx + 1]) else { return nil }
            out.append(hi << 4 | lo)
            idx += 2
        }
        self = out
    }
}

extension Double {
    /// The exact integer value, nil for fractions, NaN, infinity and anything outside the Int range
    /// (never traps, unlike `Int(_:)`).
    var exactInt: Int? { Int(exactly: self) }

    /// A display-safe integer: 0 for NaN/infinity, otherwise clamped to +-1e12 and truncated (never traps).
    var clampedInt: Int {
        guard isFinite else { return 0 }
        return Int(Swift.max(Swift.min(self, 1E12), -1E12))
    }

    /// Rounds to a number of decimal places (half away from zero).
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}

extension Date {
    /// Whole seconds since 1970 for use in identifiers (never traps).
    var epochSeconds: Int { timeIntervalSince1970.rounded(.down).clampedInt }
}

extension TimeInterval {
    static func minutes(_ m: Double) -> TimeInterval { m * 60 }
    static func hours(_ h: Double) -> TimeInterval { h * 3600 }
}

/// Date parsing for the bridge: ISO-8601 UTC, with or without fractional seconds.
enum BridgeDate {
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    private static let plain = makeFormatter(fractional: false)
    private static let fractional = makeFormatter(fractional: true)
    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return plain.date(from: string) ?? fractional.date(from: string)
    }

    static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return plain.string(from: date)
    }
}
