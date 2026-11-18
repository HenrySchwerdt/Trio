import Foundation
import LoopKit

/// Pump hardware facts (from AndroidAPS `PumpType.ACCU_CHEK_INSIGHT`, `DoseStepSize.InsightBolus/InsightBasal`).
public enum InsightPumpSpec {
    public static let minBasal = 0.02
    public static let maxBasalAbsolute = 25.0
    public static let maxBolusAbsolute = 25.0 // bridge contract: min(pump maxBolus, 25)
    public static let defaultBolusStep = 0.05
    public static let reservoirCapacity = 200.0

    public static let tbrPercentStep = 10
    public static let tbrMaxPercent = 250
    public static let tbrMinMinutes = 15
    public static let tbrMaxMinutes = 1440
    public static let tbrDurationStep = 15

    /// Bolus step by amount (U): 0.05 up to 2, 0.1 up to 5, 0.2 up to 10, 0.5 above.
    public static func bolusStep(forAmount amount: Double) -> Double {
        switch amount {
        case ..<2: return 0.05
        case ..<5: return 0.1
        case ..<10: return 0.2
        default: return 0.5
        }
    }

    /// Basal step by rate (U/h): 0.01 below 5, 0.1 above.
    public static func basalStep(forRate rate: Double) -> Double {
        rate < 5 ? 0.01 : 0.1
    }

    public static var supportedBasalRates: [Double] {
        let low = (2 ... 500).map { Double($0) / 100 } // 0.02 ... 5.00
        let high = (51 ... 250).map { Double($0) / 10 } // 5.1 ... 25.0
        return low + high
    }

    public static var supportedBolusVolumes: [Double] {
        let a = (1 ... 40).map { Double($0) / 20 } // 0.05 ... 2.00
        let b = (21 ... 50).map { Double($0) / 10 } // 2.1 ... 5.0
        let c = (26 ... 50).map { Double($0) / 5 } // 5.2 ... 10.0
        let d = (21 ... 50).map { Double($0) / 2 } // 10.5 ... 25.0
        return a + b + c + d
    }

    /// True when `value` is a multiple of `step` (tolerates floating point noise).
    static func isMultiple(_ value: Double, of step: Double, tolerance: Double = 1E-6) -> Bool {
        guard step > 0, value.isFinite else { return false }
        let ratio = value / step
        return abs(ratio - ratio.rounded()) < tolerance
    }
}

// MARK: - Temp basal (absolute U/h -> percent)

public enum TempBasalPlan: Equatable {
    /// Requested rate equals (or rounds down to) the scheduled rate: no TBR needed.
    case cancel
    /// `effectiveRate` is what the pump will actually deliver (never above the request).
    case set(percent: Int, durationMinutes: Int, effectiveRate: Double)
}

public enum TempBasalConversionError: Error, Equatable {
    case invalidRate
    case invalidDuration
    case noScheduledBasal
}

extension TempBasalConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRate: return LocalizedString("Invalid temporary basal rate.", comment: "TBR error")
        case .invalidDuration: return LocalizedString("Invalid temporary basal duration.", comment: "TBR error")
        case .noScheduledBasal:
            return LocalizedString(
                "The scheduled basal rate is 0 U/h, a temporary basal cannot be expressed as a percentage.",
                comment: "TBR error"
            )
        }
    }
}

public enum TempBasalConverter {
    /// Duration rounded **down** to 15 minute steps; at least 15, at most 1440. nil if not positive/finite.
    public static func normalizedDurationMinutes(_ duration: TimeInterval) -> Int? {
        guard duration.isFinite, duration > 0 else { return nil }
        let minutes = Int((min(duration / 60, 2 * Double(InsightPumpSpec.tbrMaxMinutes)) + 1E-6).rounded(.down))
        let stepped = (minutes / InsightPumpSpec.tbrDurationStep) * InsightPumpSpec.tbrDurationStep
        return min(max(stepped, InsightPumpSpec.tbrMinMinutes), InsightPumpSpec.tbrMaxMinutes)
    }

    /// Insight wants a percentage of the *currently scheduled* basal in 10% steps (0...250).
    /// Conservative: percent is rounded down so the pump never delivers more than requested.
    /// This flat variant assumes the scheduled rate does not change during the TBR.
    public static func plan(requestedRate: Double, scheduledRate: Double, duration: TimeInterval) throws -> TempBasalPlan {
        guard requestedRate.isFinite, requestedRate >= 0, scheduledRate.isFinite, scheduledRate >= 0 else {
            throw TempBasalConversionError.invalidRate
        }
        guard let minutes = normalizedDurationMinutes(duration) else {
            throw TempBasalConversionError.invalidDuration
        }
        return try percentPlan(requested: requestedRate, base: scheduledRate, current: scheduledRate, minutes: minutes)
    }

    /// Schedule-aware conversion. The pump keeps the *percentage* across hourly basal changes, so a TBR that
    /// runs over a boundary where the scheduled rate changes would deliver a different absolute rate afterwards.
    /// - If the first such boundary is at least 15 minutes away, the duration is shortened (15-minute steps,
    ///   rounded down) so that the TBR ends at or before it; the next loop cycle sets a new one.
    /// - If it is closer than 15 minutes the minimum duration of 15 minutes is used and the percentage is
    ///   computed against the *highest* scheduled rate of that window, so the request is never exceeded.
    public static func plan(
        requestedRate: Double, schedule: InsightBasalSchedule, at now: Date, utcOffset: Int, duration: TimeInterval
    ) throws -> TempBasalPlan {
        guard requestedRate.isFinite, requestedRate >= 0 else { throw TempBasalConversionError.invalidRate }
        guard let minutes = normalizedDurationMinutes(duration) else { throw TempBasalConversionError.invalidDuration }

        let window = now.addingTimeInterval(TimeInterval(minutes) * 60)
        let segments = schedule.rateSegments(from: now, to: window, utcOffset: utcOffset)
        guard let first = segments.first else { throw TempBasalConversionError.invalidDuration }
        let current = first.rate

        var boundary: Date?
        for index in segments.indices.dropFirst() where abs(segments[index].rate - segments[index - 1].rate) > 1E-9 {
            boundary = segments[index].start
            break
        }
        guard let boundary else {
            return try percentPlan(requested: requestedRate, base: current, current: current, minutes: minutes)
        }

        let secondsToBoundary = boundary.timeIntervalSince(now)
        let shortMinutes = Int((secondsToBoundary / 60 + 1E-6).rounded(.down)) / InsightPumpSpec.tbrDurationStep * InsightPumpSpec
            .tbrDurationStep
        if shortMinutes >= InsightPumpSpec.tbrMinMinutes {
            return try percentPlan(requested: requestedRate, base: current, current: current, minutes: min(shortMinutes, minutes))
        }
        let minimumWindow = now.addingTimeInterval(TimeInterval(InsightPumpSpec.tbrMinMinutes) * 60)
        let highest = schedule.rateSegments(from: now, to: minimumWindow, utcOffset: utcOffset).map(\.rate).max() ?? current
        return try percentPlan(requested: requestedRate, base: highest, current: current, minutes: InsightPumpSpec.tbrMinMinutes)
    }

    private static func percentPlan(requested: Double, base: Double, current: Double, minutes: Int) throws -> TempBasalPlan {
        guard requested.isFinite, requested >= 0, base.isFinite, base >= 0, current.isFinite, current >= 0 else {
            throw TempBasalConversionError.invalidRate
        }
        if base < 0.0005 {
            if requested < 0.0005 { return .cancel } // 0 of 0 is the scheduled delivery already
            throw TempBasalConversionError.noScheduledBasal
        }

        let percent = requested / base * 100
        // clamp before converting: a huge request must not trap in Int()
        let steps = Int((min(percent, 1000) / Double(InsightPumpSpec.tbrPercentStep) + 1E-6).rounded(.down))
        let rounded = min(steps * InsightPumpSpec.tbrPercentStep, InsightPumpSpec.tbrMaxPercent)

        if rounded == 100 { return .cancel }

        return .set(
            percent: rounded,
            durationMinutes: minutes,
            effectiveRate: effectiveRate(percent: rounded, scheduledRate: current)
        )
    }

    /// percent of scheduled, floored to 0.0001 U/h so it can never exceed the request through rounding.
    public static func effectiveRate(percent: Int, scheduledRate: Double) -> Double {
        let raw = Double(percent) / 100 * scheduledRate
        return (raw * 10000 + 1E-6).rounded(.down) / 10000
    }
}

// MARK: - Rate segments & TBR accounting

public struct RateSegment: Equatable {
    public let start: Date
    public let end: Date
    public let rate: Double
    public var hours: Double { end.timeIntervalSince(start) / 3600 }
}

public enum TempBasalAccounting {
    public struct Result: Equatable {
        public let averageScheduledRate: Double
        public let averageRate: Double
        public let deliveredUnits: Double
    }

    /// Insulin of a TBR with a fixed `percent`, evaluated hour by hour against the schedule that was in
    /// force when it was set. `fallbackRate` is used if no schedule is known.
    public static func account(
        percent: Int, start: Date, end: Date, schedule: InsightBasalSchedule?, utcOffset: Int, fallbackRate: Double,
        laterSchedule: InsightBasalSchedule? = nil, laterScheduleFrom: Date? = nil
    ) -> Result {
        let segments: [RateSegment]
        if let schedule, let later = laterSchedule, let from = laterScheduleFrom, from > start, from < end {
            // the profile was rewritten while the TBR ran: old rates before, new rates after
            segments = schedule.rateSegments(from: start, to: from, utcOffset: utcOffset)
                + later.rateSegments(from: from, to: end, utcOffset: utcOffset)
        } else if let schedule {
            let effective = (laterScheduleFrom.map { $0 <= start } ?? false) ? (laterSchedule ?? schedule) : schedule
            segments = effective.rateSegments(from: start, to: end, utcOffset: utcOffset)
        } else {
            segments = [RateSegment(start: start, end: max(end, start), rate: fallbackRate)]
        }
        let totalHours = segments.reduce(0) { $0 + $1.hours }
        guard totalHours > 0 else {
            let rate = TempBasalConverter.effectiveRate(percent: percent, scheduledRate: fallbackRate)
            return Result(averageScheduledRate: fallbackRate, averageRate: rate, deliveredUnits: 0)
        }
        let scheduledUnits = segments.reduce(0) { $0 + $1.rate * $1.hours }
        let averageScheduled = scheduledUnits / totalHours
        let delivered = Double(percent) / 100 * scheduledUnits
        let averageRate = TempBasalConverter.effectiveRate(percent: percent, scheduledRate: averageScheduled)
        return Result(
            averageScheduledRate: averageScheduled,
            averageRate: averageRate,
            deliveredUnits: (delivered * 1000).rounded() / 1000
        )
    }
}

// MARK: - Basal schedule

public enum BasalScheduleError: Error, Equatable {
    case empty
    case tooManyEntries(Int)
    case notHourly
    case doesNotStartAtMidnight
    case notAscending
    case rateOutOfRange(Double)
    case rateStepInvalid(Double)

    var localizedMessage: String {
        switch self {
        case .empty:
            return LocalizedString("The basal schedule is empty.", comment: "Basal schedule error")
        case let .tooManyEntries(n):
            return String(
                format: LocalizedString(
                    "The Insight supports at most 24 basal entries (got %d).",
                    comment: "Basal schedule error"
                ),
                n
            )
        case .notHourly:
            return LocalizedString(
                "The Insight only supports basal schedules that change on full hours. Please adjust your basal schedule.",
                comment: "Basal schedule error"
            )
        case .doesNotStartAtMidnight:
            return LocalizedString("The basal schedule must start at midnight.", comment: "Basal schedule error")
        case .notAscending:
            return LocalizedString("The basal schedule entries must be in ascending order.", comment: "Basal schedule error")
        case let .rateOutOfRange(r):
            return String(
                format: LocalizedString("Basal rate %.3f U/h is outside the range of the pump.", comment: "Basal schedule error"),
                r
            )
        case let .rateStepInvalid(r):
            return String(
                format: LocalizedString(
                    "Basal rate %.3f U/h is not a step the pump can deliver (0.01 U/h below 5 U/h, 0.1 U/h above).",
                    comment: "Basal schedule error"
                ),
                r
            )
        }
    }
}

extension BasalScheduleError: LocalizedError {
    public var errorDescription: String? { localizedMessage }
}

/// Insight profile segments are hourly, so the schedule is stored as 24 hourly rates.
public struct InsightBasalSchedule: Equatable, Codable {
    public let hourlyRates: [Double]

    public init?(hourlyRates: [Double]) {
        guard hourlyRates.count == 24 else { return nil }
        self.hourlyRates = hourlyRates
    }

    public static func validated(
        items: [RepeatingScheduleValue<Double>],
        minRate: Double = InsightPumpSpec.minBasal,
        maxRate: Double = InsightPumpSpec.maxBasalAbsolute
    ) throws -> InsightBasalSchedule {
        guard !items.isEmpty else { throw BasalScheduleError.empty }
        guard items.count <= 24 else { throw BasalScheduleError.tooManyEntries(items.count) }
        guard items[0].startTime == 0 else { throw BasalScheduleError.doesNotStartAtMidnight }
        // every start time is validated before any of them is converted to an hour index
        for item in items {
            guard item.startTime.isFinite, item.startTime >= 0, item.startTime < 86400,
                  InsightPumpSpec.isMultiple(item.startTime, of: 3600, tolerance: 1E-9)
            else { throw BasalScheduleError.notHourly }
        }

        var rates = [Double](repeating: 0, count: 24)
        for (index, item) in items.enumerated() {
            guard item.startTime.isFinite, item.startTime >= 0, item.startTime < 86400,
                  InsightPumpSpec.isMultiple(item.startTime, of: 3600, tolerance: 1E-9)
            else { throw BasalScheduleError.notHourly }
            if index > 0, item.startTime <= items[index - 1].startTime { throw BasalScheduleError.notAscending }

            let rate = item.value
            guard rate.isFinite, rate >= minRate - 1E-9, rate <= maxRate + 1E-9 else {
                throw BasalScheduleError.rateOutOfRange(rate)
            }
            guard InsightPumpSpec.isMultiple(rate, of: InsightPumpSpec.basalStep(forRate: rate)) else {
                throw BasalScheduleError.rateStepInvalid(rate)
            }
            let startHour = Int((item.startTime / 3600).rounded())
            let endHour = index + 1 < items.count ? Int((items[index + 1].startTime / 3600).rounded()) : 24
            guard endHour > startHour else { throw BasalScheduleError.notAscending }
            for h in startHour ..< endHour { rates[h] = rate }
        }
        return InsightBasalSchedule(hourlyRates: rates)!
    }

    /// Scheduled rate at a wall-clock moment in the given time zone.
    public func rate(at date: Date, in timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        return hourlyRates[min(max(hour, 0), 23)]
    }

    /// The schedule split at hour boundaries of the pump's local clock (fixed UTC offset).
    public func rateSegments(from start: Date, to end: Date, utcOffset: Int) -> [RateSegment] {
        guard end > start, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite else { return [] }
        var result = [RateSegment]()
        var cursor = start
        while cursor < end, result.count < 200 {
            let local = cursor.timeIntervalSince1970 + Double(utcOffset)
            let hourIndex = (local / 3600).rounded(.down)
            let hourOfDay = Int(hourIndex.truncatingRemainder(dividingBy: 24) + 24) % 24
            let boundary = Date(timeIntervalSince1970: (hourIndex + 1) * 3600 - Double(utcOffset))
            let segmentEnd = min(boundary, end)
            result.append(RateSegment(start: cursor, end: segmentEnd, rate: hourlyRates[hourOfDay]))
            cursor = segmentEnd
        }
        return result
    }

    /// Hourly rates merged into contiguous segments (1...24, durations multiples of 60 min, sum 1440).
    public var segments: [BasalSegment] {
        var result = [BasalSegment]()
        for rate in hourlyRates {
            if let last = result.last, last.rate == rate {
                result[result.count - 1] = BasalSegment(duration: last.duration + 60, rate: rate)
            } else {
                result.append(BasalSegment(duration: 60, rate: rate))
            }
        }
        return result
    }

    public func scheduleItems() -> [RepeatingScheduleValue<Double>] {
        var items = [RepeatingScheduleValue<Double>]()
        var start = 0
        for segment in segments {
            items.append(RepeatingScheduleValue(startTime: TimeInterval(start * 60), value: segment.rate))
            start += segment.duration
        }
        return items
    }
}

// MARK: - Bolus validation

public enum BolusValidationError: Error, Equatable {
    case notPositive
    case exceedsMaximum(Double)
    case notMultipleOfStep(Double)
    case exceedsReservoir(Double)
}

extension BolusValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPositive:
            return LocalizedString("The bolus amount must be greater than 0.", comment: "Bolus error")
        case let .exceedsMaximum(max):
            return String(format: LocalizedString("The bolus exceeds the maximum of %.2f U.", comment: "Bolus error"), max)
        case let .notMultipleOfStep(step):
            return String(format: LocalizedString("The bolus is not a multiple of %.2f U.", comment: "Bolus error"), step)
        case let .exceedsReservoir(units):
            return String(format: LocalizedString("The reservoir only holds %.1f U.", comment: "Bolus error"), units)
        }
    }
}

public enum BolusValidator {
    /// The step that applies to `units`: the pump's amount-dependent grid, never finer than the bridge's step.
    public static func step(for units: Double, bridgeStep: Double) -> Double {
        max(bridgeStep, InsightPumpSpec.bolusStep(forAmount: units.isFinite ? units : 0))
    }

    /// Rejects (never clamps) invalid amounts. `maxBolus` is the minimum of all known limits.
    public static func validate(units: Double, maxBolus: Double, step: Double, reservoir: Double?) throws {
        guard units.isFinite, units > 0 else { throw BolusValidationError.notPositive }
        guard units <= maxBolus + 1E-9 else { throw BolusValidationError.exceedsMaximum(maxBolus) }
        guard InsightPumpSpec.isMultiple(units, of: step) else { throw BolusValidationError.notMultipleOfStep(step) }
        if let reservoir, units > reservoir + 1E-9 { throw BolusValidationError.exceedsReservoir(reservoir) }
    }
}
