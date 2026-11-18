@testable import InsightKit
import LoopKit
import XCTest

final class TempBasalConversionTests: XCTestCase {
    private func plan(_ rate: Double, scheduled: Double = 1.0, minutes: Double = 30) throws -> TempBasalPlan {
        try TempBasalConverter.plan(requestedRate: rate, scheduledRate: scheduled, duration: minutes * 60)
    }

    func testZeroRateIsZeroPercent() throws {
        XCTAssertEqual(try plan(0), .set(percent: 0, durationMinutes: 30, effectiveRate: 0))
    }

    func testExactScheduledRateCancelsTBR() throws {
        XCTAssertEqual(try plan(1.0), .cancel)
        XCTAssertEqual(try plan(0.85, scheduled: 0.85), .cancel)
    }

    func testRoundsPercentDownNeverUp() throws {
        // 1.19 U/h of 1.0 = 119% -> 110%
        XCTAssertEqual(try plan(1.19), .set(percent: 110, durationMinutes: 30, effectiveRate: 1.1))
        // 0.79 of 1.0 = 79% -> 70%
        XCTAssertEqual(try plan(0.79), .set(percent: 70, durationMinutes: 30, effectiveRate: 0.7))
        // just below 100% (99.9%) -> 90%, never 100
        XCTAssertEqual(try plan(0.999), .set(percent: 90, durationMinutes: 30, effectiveRate: 0.9))
        // requests between 100 and 110 percent cannot be expressed: no TBR (never more than requested)
        XCTAssertEqual(try plan(1.09), .cancel)
    }

    func testFloatingPointNoiseDoesNotLoseAStep() throws {
        // 0.3 / 1.0 * 100 = 30.000000000000004 (and 0.7/1.0 sometimes 69.99999999999999)
        XCTAssertEqual(try plan(0.7), .set(percent: 70, durationMinutes: 30, effectiveRate: 0.7))
        XCTAssertEqual(try plan(0.3), .set(percent: 30, durationMinutes: 30, effectiveRate: 0.3))
        XCTAssertEqual(try plan(1.1, scheduled: 1.0), .set(percent: 110, durationMinutes: 30, effectiveRate: 1.1))
        XCTAssertEqual(try plan(0.58, scheduled: 0.8), .set(percent: 70, durationMinutes: 30, effectiveRate: 0.56))
    }

    func testCapAtTwoHundredFiftyPercent() throws {
        XCTAssertEqual(try plan(2.5), .set(percent: 250, durationMinutes: 30, effectiveRate: 2.5))
        XCTAssertEqual(try plan(2.6), .set(percent: 250, durationMinutes: 30, effectiveRate: 2.5))
        XCTAssertEqual(try plan(10.0), .set(percent: 250, durationMinutes: 30, effectiveRate: 2.5))
    }

    func testEffectiveRateNeverExceedsRequestAboveBaseline() throws {
        for scheduled in stride(from: 0.05, through: 3.0, by: 0.05) {
            for requested in stride(from: 0.0, through: scheduled * 2.5, by: 0.037) {
                if case let .set(_, _, rate) = try plan(requested, scheduled: scheduled) {
                    XCTAssertLessThanOrEqual(rate, requested + 1E-9, "scheduled \(scheduled) requested \(requested)")
                }
            }
        }
    }

    func testDurationsRoundDownToFifteenMinutes() throws {
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(30 * 60), 30)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(44 * 60), 30)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(45 * 60), 45)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(59.9 * 60), 45)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(60 * 60), 60)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(7 * 60), 15, "minimum is 15")
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(15 * 60), 15)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(48 * 3600), 1440, "maximum is 24 h")
        XCTAssertNil(TempBasalConverter.normalizedDurationMinutes(0))
        XCTAssertNil(TempBasalConverter.normalizedDurationMinutes(-5))
        XCTAssertNil(TempBasalConverter.normalizedDurationMinutes(.nan))
        XCTAssertEqual(try plan(0.5, minutes: 44), .set(percent: 50, durationMinutes: 30, effectiveRate: 0.5))
    }

    func testInvalidInputs() {
        XCTAssertThrowsError(try plan(-0.1)) { XCTAssertEqual($0 as? TempBasalConversionError, .invalidRate) }
        XCTAssertThrowsError(try plan(.nan)) { XCTAssertEqual($0 as? TempBasalConversionError, .invalidRate) }
        XCTAssertThrowsError(try plan(1, scheduled: .infinity)) { XCTAssertEqual($0 as? TempBasalConversionError, .invalidRate) }
        XCTAssertThrowsError(try plan(1, minutes: 0)) { XCTAssertEqual($0 as? TempBasalConversionError, .invalidDuration) }
    }

    func testZeroScheduledBasal() throws {
        XCTAssertEqual(try plan(0, scheduled: 0), .cancel)
        XCTAssertThrowsError(try plan(0.5, scheduled: 0)) { XCTAssertEqual($0 as? TempBasalConversionError, .noScheduledBasal) }
    }
}

final class BolusValidationTests: XCTestCase {
    func testValidBolus() throws {
        try BolusValidator.validate(units: 1.25, maxBolus: 10, step: 0.05, reservoir: 100)
        try BolusValidator.validate(units: 10, maxBolus: 10, step: 0.05, reservoir: nil)
        try BolusValidator.validate(units: 0.05, maxBolus: 10, step: 0.05, reservoir: 0.05)
    }

    func testInvalidBolusIsRejectedNotClamped() {
        XCTAssertThrowsError(try BolusValidator.validate(units: 0, maxBolus: 10, step: 0.05, reservoir: 1)) {
            XCTAssertEqual($0 as? BolusValidationError, .notPositive) }
        XCTAssertThrowsError(try BolusValidator.validate(units: -1, maxBolus: 10, step: 0.05, reservoir: 1)) {
            XCTAssertEqual($0 as? BolusValidationError, .notPositive) }
        XCTAssertThrowsError(try BolusValidator.validate(units: .nan, maxBolus: 10, step: 0.05, reservoir: 1)) {
            XCTAssertEqual($0 as? BolusValidationError, .notPositive) }
        XCTAssertThrowsError(try BolusValidator.validate(units: 10.05, maxBolus: 10, step: 0.05, reservoir: 100)) {
            XCTAssertEqual($0 as? BolusValidationError, .exceedsMaximum(10)) }
        XCTAssertThrowsError(try BolusValidator.validate(units: 1.23, maxBolus: 10, step: 0.05, reservoir: 100)) {
            XCTAssertEqual($0 as? BolusValidationError, .notMultipleOfStep(0.05)) }
        XCTAssertThrowsError(try BolusValidator.validate(units: 5, maxBolus: 10, step: 0.05, reservoir: 4.9)) {
            XCTAssertEqual($0 as? BolusValidationError, .exceedsReservoir(4.9)) }
    }

    func testStepFloatingPointNoise() throws {
        for i in 1 ... 200 { try BolusValidator.validate(units: Double(i) * 0.05, maxBolus: 25, step: 0.05, reservoir: nil) }
    }

    func testSupportedVolumesFollowInsightSteps() {
        let volumes = InsightPumpSpec.supportedBolusVolumes
        XCTAssertEqual(volumes.first, 0.05)
        XCTAssertEqual(volumes.last, 25.0)
        XCTAssertTrue(volumes.contains(1.95))
        XCTAssertTrue(volumes.contains(2.1))
        XCTAssertTrue(volumes.contains(5.2))
        XCTAssertFalse(volumes.contains(2.05))
        XCTAssertFalse(volumes.contains(5.1))
        XCTAssertFalse(volumes.contains(10.1))
        XCTAssertEqual(volumes, volumes.sorted())
        for v in volumes { XCTAssertTrue(InsightPumpSpec.isMultiple(v, of: 0.05), "\(v)") }
    }

    func testSupportedBasalRates() {
        let rates = InsightPumpSpec.supportedBasalRates
        XCTAssertEqual(rates.first, 0.02)
        XCTAssertEqual(rates.last, 25.0)
        XCTAssertTrue(rates.contains(4.99))
        XCTAssertTrue(rates.contains(5.1))
        XCTAssertFalse(rates.contains(5.05))
        XCTAssertEqual(rates, rates.sorted())
    }
}

final class BasalScheduleTests: XCTestCase {
    private func items(_ pairs: [(Double, Double)]) -> [RepeatingScheduleValue<Double>] {
        pairs.map { RepeatingScheduleValue(startTime: $0.0 * 3600, value: $0.1) }
    }

    func testValidScheduleExpandsToHours() throws {
        let schedule = try InsightBasalSchedule.validated(items: items([(0, 0.8), (6, 1.0), (22, 0.7)]))
        XCTAssertEqual(schedule.hourlyRates[0], 0.8)
        XCTAssertEqual(schedule.hourlyRates[5], 0.8)
        XCTAssertEqual(schedule.hourlyRates[6], 1.0)
        XCTAssertEqual(schedule.hourlyRates[21], 1.0)
        XCTAssertEqual(schedule.hourlyRates[23], 0.7)
        XCTAssertEqual(
            schedule.segments,
            [
                BasalSegment(duration: 360, rate: 0.8),
                BasalSegment(duration: 960, rate: 1.0),
                BasalSegment(duration: 120, rate: 0.7)
            ]
        )
        XCTAssertEqual(schedule.segments.map(\.duration).reduce(0, +), 1440)
        XCTAssertEqual(schedule.scheduleItems().map(\.startTime), [0.0, 6.0 * 3600, 22.0 * 3600])
    }

    func testTwentyFourEntriesAreAccepted() throws {
        let schedule = try InsightBasalSchedule.validated(items: items((0 ..< 24).map { (Double($0), 0.5 + Double($0) * 0.01) }))
        XCTAssertEqual(schedule.segments.count, 24)
    }

    func testNonHourlyScheduleIsRejectedWithClearMessage() {
        let half = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 1800, value: 1.2)]
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: half)) { error in
            XCTAssertEqual(error as? BasalScheduleError, .notHourly)
            XCTAssertTrue(error.localizedDescription.contains("full hours"))
        }
        let odd = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 3600 + 60, value: 1.2)]
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: odd)) {
            XCTAssertEqual($0 as? BasalScheduleError, .notHourly) }
    }

    func testStructuralErrors() {
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: [])) { XCTAssertEqual($0 as? BasalScheduleError, .empty) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(1, 1.0)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .doesNotStartAtMidnight) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 1.0), (5, 1.0), (5, 1.1)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .notAscending) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 1.0), (6, 1.0), (5, 1.0)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .notAscending) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items((0 ... 24).map { (Double($0), 1.0) }))) { error in
            if case .tooManyEntries = error as? BasalScheduleError {} else { XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 1.0), (24, 1.0)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .notHourly) }
    }

    func testRateRangeAndStepAreEnforced() {
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 0.01)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateOutOfRange(0.01)) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 0.0)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateOutOfRange(0)) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 25.5)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateOutOfRange(25.5)) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 1.005)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateStepInvalid(1.005)) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 5.05)]))) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateStepInvalid(5.05)) }
        XCTAssertNoThrow(try InsightBasalSchedule.validated(items: items([(0, 5.1)])))
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 3.0)]), maxRate: 2.5)) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateOutOfRange(3.0)) }
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items([(0, 0.05)]), minRate: 0.1)) {
            XCTAssertEqual($0 as? BasalScheduleError, .rateOutOfRange(0.05)) }
    }

    func testRateLookupUsesPumpTimeZone() throws {
        let schedule = try InsightBasalSchedule.validated(items: items([(0, 0.8), (12, 1.6)]))
        let utcNoon = date("2026-11-18T12:30:00Z")
        XCTAssertEqual(schedule.rate(at: utcNoon, in: TimeZone(secondsFromGMT: 0)!), 1.6)
        XCTAssertEqual(schedule.rate(at: utcNoon, in: TimeZone(secondsFromGMT: -3 * 3600)!), 0.8)
        XCTAssertEqual(schedule.rate(at: utcNoon, in: TimeZone(secondsFromGMT: 3600)!), 1.6)
    }

    func testScheduleIsCodable() throws {
        let schedule = try InsightBasalSchedule.validated(items: items([(0, 0.8), (6, 1.0)]))
        let data = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(InsightBasalSchedule.self, from: data), schedule)
    }
}
