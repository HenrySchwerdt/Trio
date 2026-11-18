@testable import InsightKit
import LoopKit
import XCTest

final class HistoryMapperTests: XCTestCase {
    private func event(_ seq: Int, _ type: String, _ time: String, _ data: String) -> HistoryEvent {
        HistoryEvent(seq: seq, time: date(time), type: type, data: json(data))
    }

    private var schedule: InsightBasalSchedule {
        InsightBasalSchedule(hourlyRates: Array(repeating: 1.0, count: 24))!
    }

    private func context(bolus: UnfinalizedBolus? = nil, tbrs: [ActiveTempBasal] = []) -> HistoryMappingContext {
        HistoryMappingContext(
            serial: "SN1",
            schedule: schedule,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            insulinType: .novolog,
            bolus: bolus,
            tempBasals: tbrs
        )
    }

    // MARK: dedupe

    func testNewEventsDropsOldAndDuplicatesAndSorts() {
        let events = [
            event(5, "other", "2026-11-18T10:00:00Z", "{}"), event(3, "other", "2026-11-18T10:00:00Z", "{}"),
            event(5, "other", "2026-11-18T10:00:00Z", "{}"), event(4, "other", "2026-11-18T10:00:00Z", "{}")
        ]
        XCTAssertEqual(HistoryMapper.newEvents(events, after: 3).map(\.seq), [4, 5])
        XCTAssertEqual(HistoryMapper.newEvents(events, after: nil).map(\.seq), [3, 4, 5])
        XCTAssertTrue(HistoryMapper.newEvents(events, after: 5).isEmpty)
    }

    func testSyncIdentifiersAreStableAcrossRuns() {
        let e = event(10, "tubeFilled", "2026-11-18T10:00:00Z", #"{"units":10}"#)
        let a = HistoryMapper.map([e], context: context()).events
        let b = HistoryMapper.map([e], context: context()).events
        XCTAssertEqual(a.map(\.raw), b.map(\.raw))
        XCTAssertEqual(a.first?.type, .prime)
        let other = HistoryMapper.map([event(11, "tubeFilled", "2026-11-18T10:00:00Z", #"{"units":10}"#)], context: context())
            .events
        XCTAssertNotEqual(a.first?.raw, other.first?.raw, "different seq -> different identifier")
    }

    // MARK: boluses

    func testDeliveredBolusBecomesFinalDose() throws {
        let e = event(
            2,
            "bolusDelivered",
            "2026-11-18T10:01:00Z",
            #"{"bolusId":1,"bolusType":"standard","programmed":2.0,"delivered":1.4,"start":"2026-11-18T10:00:00Z","end":"2026-11-18T10:00:30Z"}"#
        )
        let result = HistoryMapper.map([e], context: context())
        let dose = try XCTUnwrap(result.events.first?.dose)
        XCTAssertEqual(dose.type, .bolus)
        XCTAssertEqual(dose.value, 2.0)
        XCTAssertEqual(dose.deliveredUnits, 1.4)
        XCTAssertFalse(dose.isMutable)
        XCTAssertEqual(dose.startDate, date("2026-11-18T10:00:00Z"))
        XCTAssertEqual(dose.endDate, date("2026-11-18T10:00:30Z"))
        XCTAssertTrue(dose.wasProgrammedByPumpUI, "no matching Trio bolus")
        XCTAssertEqual(result.events.first?.type, .bolus)
    }

    func testBolusMatchingOurUnfinalizedDoseKeepsDecisionAndIsReported() throws {
        let decision = UUID()
        let bolus = UnfinalizedBolus(
            requestId: "r",
            units: 2.0,
            startDate: date("2026-11-18T10:00:00Z"),
            bolusId: 1,
            decisionId: decision,
            automatic: true,
            insulinType: nil,
            deliveredUnits: 0,
            phase: .inProgress,
            endDate: nil,
            programmedOnPump: false
        )
        let e = event(
            2,
            "bolusDelivered",
            "2026-11-18T10:01:00Z",
            #"{"bolusId":1,"bolusType":"standard","programmed":2.0,"delivered":2.0,"start":"2026-11-18T10:00:01Z","end":"2026-11-18T10:00:50Z"}"#
        )
        let result = HistoryMapper.map([e], context: context(bolus: bolus))
        XCTAssertNotNil(result.matchedBolusEvent)
        let dose = try XCTUnwrap(result.events.first?.dose)
        XCTAssertEqual(dose.decisionId, decision)
        XCTAssertEqual(dose.automatic, true)
        XCTAssertFalse(dose.wasProgrammedByPumpUI)
    }

    func testBolusMatchingFallsBackToAmountAndTimeWhenIdUnknown() {
        let bolus = UnfinalizedBolus(
            requestId: "r",
            units: 1.5,
            startDate: date("2026-11-18T10:00:00Z"),
            bolusId: nil,
            decisionId: nil,
            automatic: false,
            insulinType: nil,
            deliveredUnits: 0,
            phase: .inProgress,
            endDate: nil,
            programmedOnPump: false
        )
        let near = event(
            2,
            "bolusDelivered",
            "2026-11-18T10:01:00Z",
            #"{"bolusId":9,"programmed":1.5,"delivered":1.5,"start":"2026-11-18T10:00:02Z","end":"2026-11-18T10:00:40Z"}"#
        )
        let wrongAmount = event(
            3,
            "bolusDelivered",
            "2026-11-18T10:01:00Z",
            #"{"bolusId":9,"programmed":1.0,"delivered":1.0,"start":"2026-11-18T10:00:02Z","end":"2026-11-18T10:00:40Z"}"#
        )
        let wrongTime = event(
            4,
            "bolusDelivered",
            "2026-11-18T14:01:00Z",
            #"{"bolusId":9,"programmed":1.5,"delivered":1.5,"start":"2026-11-18T14:00:02Z","end":"2026-11-18T14:00:40Z"}"#
        )
        XCTAssertTrue(HistoryMapper.matches(bolus, near))
        XCTAssertFalse(HistoryMapper.matches(bolus, wrongAmount))
        XCTAssertFalse(HistoryMapper.matches(bolus, wrongTime))
    }

    func testImplausibleBolusEventsAreHandledConservativelyAndBlockTheSequence() throws {
        let contradicting = event(1, "bolusDelivered", "2026-11-18T10:01:00Z", #"{"programmed":1.0,"delivered":5.0}"#)
        let missing = event(2, "bolusDelivered", "2026-11-18T10:01:00Z", #"{}"#)
        let negative = event(3, "bolusDelivered", "2026-11-18T10:01:00Z", #"{"programmed":-1,"delivered":-1}"#)
        let result = HistoryMapper.map([contradicting, missing, negative], context: context())
        XCTAssertEqual(result.events.count, 3)
        // the contradicting numbers count with the larger value (more insulin on board is the safe side)
        XCTAssertEqual(result.events[0].dose?.deliveredUnits, 5.0)
        XCTAssertNil(result.events[1].dose)
        XCTAssertNil(result.events[2].dose)
        XCTAssertEqual(result.unreadableSequences, [1, 2, 3])
    }

    func testBolusProgrammedAloneProducesNoDose() {
        let e = event(1, "bolusProgrammed", "2026-11-18T10:00:00Z", #"{"bolusId":1,"amount":1.0}"#)
        XCTAssertTrue(HistoryMapper.map([e], context: context()).events.isEmpty)
    }

    // MARK: temp basal

    func testTbrEndBecomesFinalTempBasalWithActualDuration() throws {
        let e = event(4, "tbrEnd", "2026-11-18T10:20:00Z", #"{"percent":150,"duration":20}"#)
        let result = HistoryMapper.map([e], context: context())
        let dose = try XCTUnwrap(result.events.first?.dose)
        XCTAssertEqual(dose.type, .tempBasal)
        XCTAssertEqual(dose.startDate, date("2026-11-18T10:00:00Z"))
        XCTAssertEqual(dose.endDate, date("2026-11-18T10:20:00Z"))
        XCTAssertEqual(dose.unitsPerHour, 1.5, accuracy: 1E-9)
        XCTAssertEqual(dose.scheduledBasalRate?.doubleValue(for: DoseEntry.unitsPerHour), 1.0)
        XCTAssertEqual(dose.deliveredUnits ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(dose.isMutable)
    }

    func testTbrEndMatchesOurRunningTbrAndReportsItFinalized() throws {
        let decision = UUID()
        let tbr = ActiveTempBasal(
            percent: 150,
            durationMinutes: 30,
            start: date("2026-11-18T10:00:30Z"),
            scheduledRate: 1.0,
            effectiveRate: 1.5,
            decisionId: decision,
            automatic: true,
            endedAt: nil
        )
        let e = event(4, "tbrEnd", "2026-11-18T10:30:00Z", #"{"percent":150,"duration":30}"#)
        let result = HistoryMapper.map([e], context: context(tbrs: [tbr]))
        XCTAssertEqual(result.matchedTempBasalStarts, [tbr.start])
        XCTAssertEqual(result.events.first?.dose?.decisionId, decision)
    }

    func testTbrStartIsInformationalOnly() {
        let e = event(3, "tbrStart", "2026-11-18T10:00:00Z", #"{"percent":120,"duration":30}"#)
        let result = HistoryMapper.map([e], context: context())
        XCTAssertNil(result.events.first?.dose)
        XCTAssertTrue(result.events.first?.title.contains("120") == true)
    }

    func testTbrEndWithoutScheduleIsInformational() {
        var ctx = context()
        ctx.schedule = nil
        let result = HistoryMapper.map(
            [event(4, "tbrEnd", "2026-11-18T10:30:00Z", #"{"percent":150,"duration":30}"#)],
            context: ctx
        )
        XCTAssertNil(result.events.first?.dose)
    }

    // MARK: suspend / resume / fills / alerts

    func testOperatingModeChanges() {
        let suspend = event(1, "operatingModeChanged", "2026-11-18T10:00:00Z", #"{"oldMode":"started","newMode":"stopped"}"#)
        let resume = event(2, "operatingModeChanged", "2026-11-18T10:10:00Z", #"{"oldMode":"stopped","newMode":"started"}"#)
        let paused = event(3, "operatingModeChanged", "2026-11-18T10:20:00Z", #"{"oldMode":"started","newMode":"paused"}"#)
        let noop = event(4, "operatingModeChanged", "2026-11-18T10:30:00Z", #"{"oldMode":"started","newMode":"started"}"#)
        let events = HistoryMapper.map([suspend, resume, paused, noop], context: context()).events
        XCTAssertEqual(events.map(\.type), [.suspend, .resume, .suspend, nil])
        XCTAssertEqual(events[0].dose?.type, .suspend)
        XCTAssertEqual(events[1].dose?.type, .resume)
    }

    func testCartridgeTubeCannulaMapping() {
        let removed = event(1, "cartridgeRemoved", "2026-11-18T10:00:00Z", "{}")
        let inserted = event(2, "cartridgeInserted", "2026-11-18T10:01:00Z", #"{"units":160}"#)
        let tube = event(3, "tubeFilled", "2026-11-18T10:02:00Z", #"{"units":18}"#)
        let cannula = event(4, "cannulaFilled", "2026-11-18T10:03:00Z", #"{"units":0.5}"#)
        let events = HistoryMapper.map([removed, inserted, tube, cannula], context: context()).events
        XCTAssertEqual(events.map(\.type), [.rewind, nil, .prime, .prime])
        XCTAssertTrue(events.allSatisfy { $0.dose == nil })
    }

    func testAlertEventsBecomeAlarms() throws {
        let low = event(
            1,
            "alert",
            "2026-11-18T10:00:00Z",
            #"{"alertId":3,"alertType":"W31_CARTRIDGE_LOW","category":"warning"}"#
        )
        let error = event(
            2,
            "alert",
            "2026-11-18T10:01:00Z",
            #"{"alertId":4,"alertType":"E7_ELECTRONIC_ERROR","category":"error"}"#
        )
        let events = HistoryMapper.map([low, error], context: context()).events
        XCTAssertEqual(events.map(\.type), [.alarm, .alarm])
        XCTAssertEqual(events[0].alarmType, .lowInsulin)
        if case .other = try XCTUnwrap(events[1].alarmType) {} else { XCTFail() }
    }

    func testRemainingTypesAreInformational() {
        let events = [
            event(1, "basalRateChanged", "2026-11-18T10:00:00Z", #"{"oldRate":0.8,"newRate":0.9}"#),
            event(2, "totalDailyDose", "2026-11-18T10:00:00Z", #"{"total":22}"#),
            event(3, "dateTimeChanged", "2026-11-18T10:00:00Z", #"{"old":"a","new":"b"}"#),
            event(4, "other", "2026-11-18T10:00:00Z", #"{"raw":"PowerUp"}"#),
            event(5, "neverSeenBefore", "2026-11-18T10:00:00Z", "null")
        ]
        let mapped = HistoryMapper.map(events, context: context())
        XCTAssertEqual(mapped.events.count, 5)
        XCTAssertTrue(mapped.events.allSatisfy { $0.dose == nil })
        XCTAssertEqual(mapped.highestSequence, 5)
    }
}
