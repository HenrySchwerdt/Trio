@testable import InsightKit
import LoopKit
import XCTest

// Regression tests for the independent safety review (H1-H4, M1-M8, low findings).

private func runningTbr(_ h: ManagerHarness, percent: Int = 150) -> BridgeStatus.TBR {
    BridgeStatus.TBR(percent: percent, duration: 30, remaining: 25, start: h.now.addingTimeInterval(-300))
}

// MARK: - H1

final class H1QueuedCommandsTests: XCTestCase {
    func testQueuedCommandsNeverOverwriteAnUncertainBolus() throws {
        let h = ManagerHarness()
        h.client.status = h.status(tbr: runningTbr(h))
        h.ensureData() // a TBR is running, so cancel-TBR has real work
        XCTAssertNotNil(h.state.runningTempBasal(at: h.now))

        h.client.holdBolus = true
        h.client.bolusResult = .failure(.timeout)
        var bolusError: PumpManagerError?
        var suspendError: Error?
        var cancelError: PumpManagerError?
        var tbrError: PumpManagerError?
        var profileResult: Result<BasalRateSchedule, Error>?
        h.manager.enactBolus(decisionId: nil, units: 1, activationType: .automatic) { bolusError = $0 }
        // all of these pass their entry checks (nothing is uncertain yet) and wait behind the bolus
        h.manager.suspendDelivery { suspendError = $0 }
        h.manager.enactTempBasal(decisionId: nil, unitsPerHour: 1.0, for: 0) { cancelError = $0 }
        h.manager.enactTempBasal(decisionId: nil, unitsPerHour: 0.5, for: 30 * 60) { tbrError = $0 }
        h.manager.syncBasalRateSchedule(items: [RepeatingScheduleValue(startTime: 0, value: 0.9)]) { profileResult = $0 }
        h.settle()
        XCTAssertTrue(h.client.modeCalls.isEmpty)

        h.client.releaseBolus() // the bolus now times out -> uncertain
        h.settle()

        XCTAssertTrue(isUncertain(bolusError))
        let pending = try XCTUnwrap(h.state.pendingCommand)
        XCTAssertEqual(pending.kind, .bolus, "the uncertain bolus record is still there")
        XCTAssertEqual(pending.requestId, h.client.deliverBolusCalls.first?.requestId)
        XCTAssertTrue(pending.isUncertain)

        // Commands that ADD insulin or change the profile are refused ...
        guard case .deviceState? = tbrError else { return XCTFail() }
        guard case let .failure(error)? = profileResult, case .deviceState = error as? PumpManagerError else { return XCTFail() }
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
        XCTAssertTrue(h.client.profileCalls.isEmpty)
        // ... risk reducing ones went through, each without touching the bolus record.
        XCTAssertNil(suspendError)
        XCTAssertNil(cancelError)
        XCTAssertEqual(h.client.modeCalls, [.stopped])
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
    }

    func testBeginPendingNeverOverwritesAnyRecordedCommand() {
        let h = ManagerHarness()
        func command(_ id: String) -> PendingCommand {
            PendingCommand(
                kind: .suspend,
                requestId: id,
                sentDate: Date(),
                baselineSequence: nil,
                units: nil,
                percent: nil,
                durationMinutes: nil,
                scheduledRate: nil,
                decisionId: nil,
                automatic: false,
                insulinType: nil,
                isUncertain: false
            )
        }
        XCTAssertTrue(h.queue.sync { h.manager.beginPending(command("first")) })
        XCTAssertFalse(h.queue.sync { h.manager.beginPending(command("second")) })
        XCTAssertEqual(h.state.pendingCommand?.requestId, "first")
    }
}

// MARK: - H2

final class H2TempBasalAcrossHoursTests: XCTestCase {
    /// 0.5 U/h until 11:00, 1.5 U/h afterwards
    private var schedule: InsightBasalSchedule {
        InsightBasalSchedule(hourlyRates: (0 ..< 24).map { $0 < 11 ? 0.5 : 1.5 })!
    }

    private func plan(
        _ rate: Double,
        at time: String,
        minutes: Double,
        schedule: InsightBasalSchedule? = nil
    ) throws -> TempBasalPlan {
        try TempBasalConverter.plan(
            requestedRate: rate,
            schedule: schedule ?? self.schedule,
            at: date("2026-11-18T\(time)Z"),
            utcOffset: 0,
            duration: minutes * 60
        )
    }

    private func assertNeverAboveRequest(
        _ plan: TempBasalPlan,
        rate: Double,
        at time: String,
        schedule: InsightBasalSchedule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .set(percent, minutes, _) = plan else { return }
        let start = date("2026-11-18T\(time)Z")
        let segments = schedule.rateSegments(from: start, to: start.addingTimeInterval(TimeInterval(minutes) * 60), utcOffset: 0)
        for segment in segments {
            XCTAssertLessThanOrEqual(
                Double(percent) / 100 * segment.rate,
                rate + 1E-9,
                "segment at \(segment.start)",
                file: file,
                line: line
            )
        }
    }

    func testReviewersExampleNoLongerDeliversMoreThanRequested() throws {
        // 10:50, 0.8 U/h for 30 min. Old behaviour: 160% of 0.5 -> 2.4 U/h after 11:00.
        let result = try plan(0.8, at: "10:50:00", minutes: 30)
        // boundary is 10 min away (< 15): minimum 15 min, percentage against the highest rate (1.5) -> 50%
        XCTAssertEqual(result, .set(percent: 50, durationMinutes: 15, effectiveRate: 0.25))
        assertNeverAboveRequest(result, rate: 0.8, at: "10:50:00", schedule: schedule)
    }

    func testDurationIsShortenedToEndAtTheBoundary() throws {
        // 10:20: the rate changes in 40 minutes -> 30 minutes (floored to 15-minute steps), percent against 0.5
        XCTAssertEqual(try plan(0.6, at: "10:20:00", minutes: 60), .set(percent: 120, durationMinutes: 30, effectiveRate: 0.6))
        // 10:00 sharp: 60 minutes to the boundary -> the requested 30 minutes fit
        XCTAssertEqual(try plan(0.6, at: "10:00:00", minutes: 30), .set(percent: 120, durationMinutes: 30, effectiveRate: 0.6))
        // exactly 15 minutes away: 15 minutes
        XCTAssertEqual(try plan(0.6, at: "10:45:00", minutes: 60), .set(percent: 120, durationMinutes: 15, effectiveRate: 0.6))
        // 14 min 59 s away: minimum duration, highest rate of the window
        XCTAssertEqual(try plan(0.6, at: "10:45:01", minutes: 60), .set(percent: 40, durationMinutes: 15, effectiveRate: 0.2))
    }

    func testNoChangeInTheWindowKeepsTheRequestedDuration() throws {
        // after 11:00 the rate is a constant 1.5 U/h: 0.6 is 40%
        XCTAssertEqual(try plan(0.6, at: "12:00:00", minutes: 60), .set(percent: 40, durationMinutes: 60, effectiveRate: 0.6))
        XCTAssertEqual(try plan(0.5, at: "03:10:00", minutes: 45), .cancel, "equal to the scheduled rate")
        XCTAssertEqual(try plan(0.75, at: "03:10:00", minutes: 45), .set(percent: 150, durationMinutes: 45, effectiveRate: 0.75))
    }

    func testChangeWhereRateDropsIsHandledToo() throws {
        let falling = InsightBasalSchedule(hourlyRates: (0 ..< 24).map { $0 < 11 ? 1.5 : 0.5 })!
        // 10:55: 5 min to a drop to 0.5: the request 0.6 vs max 1.5 -> 40% -> 0.6 U/h now, 0.2 U/h after
        let result = try plan(0.6, at: "10:55:00", minutes: 30, schedule: falling)
        XCTAssertEqual(result, .set(percent: 40, durationMinutes: 15, effectiveRate: 0.6))
        assertNeverAboveRequest(result, rate: 0.6, at: "10:55:00", schedule: falling)
    }

    func testPumpClockOffsetDecidesWhereTheBoundaryIs() throws {
        // 09:50 UTC is 10:50 at +1h: same situation as the reviewer's example
        let result = try TempBasalConverter.plan(
            requestedRate: 0.8, schedule: schedule, at: date("2026-11-18T09:50:00Z"), utcOffset: 3600, duration: 30 * 60
        )
        XCTAssertEqual(result, .set(percent: 50, durationMinutes: 15, effectiveRate: 0.25))
    }

    func testNeverExceedsTheRequestForRandomSchedulesTimesAndRequests() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 3000 {
            var rates = [Double]()
            for _ in 0 ..< 24 { rates.append(Double(Int.random(in: 2 ... 300, using: &generator)) / 100) }
            let sched = InsightBasalSchedule(hourlyRates: rates)!
            let minuteOfDay = Int.random(in: 0 ..< 1440, using: &generator)
            let second = Int.random(in: 0 ..< 60, using: &generator)
            let time = String(format: "%02d:%02d:%02d", minuteOfDay / 60, minuteOfDay % 60, second)
            let request = Double(Int.random(in: 0 ... 700, using: &generator)) / 100
            let duration = Double(Int.random(in: 1 ... 1500, using: &generator))
            let result = try plan(request, at: time, minutes: duration, schedule: sched)
            assertNeverAboveRequest(result, rate: request, at: time, schedule: sched)
            if case let .set(_, minutes, _) = result {
                XCTAssertEqual(minutes % 15, 0)
                XCTAssertTrue((15 ... 1440).contains(minutes))
            }
        }
    }

    func testManagerSendsTheShortenedTbr() {
        let h = ManagerHarness { state in
            state.basalSchedule = InsightBasalSchedule(hourlyRates: (0 ..< 24).map { $0 < 11 ? 0.5 : 1.5 })
            state.pumpTimeZoneOffsetSeconds = 0
        }
        h.now = date("2026-11-18T10:50:00Z")
        h.client.status = h.status(basalRate: 0.5)
        XCTAssertNil(h.tbr(0.8, minutes: 30))
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
        XCTAssertEqual(h.client.setTbrCalls[0].percent, 50)
        XCTAssertEqual(h.client.setTbrCalls[0].duration, 15)
    }

    func testTbrRecordKeepsTheScheduleSnapshotAndCostsPerSegment() throws {
        let h = ManagerHarness { state in
            state.basalSchedule = InsightBasalSchedule(hourlyRates: (0 ..< 24).map { $0 < 11 ? 0.5 : 1.5 })
            state.pumpTimeZoneOffsetSeconds = 0
        }
        h.now = date("2026-11-18T10:50:00Z")
        h.client.status = h.status(basalRate: 0.5)
        XCTAssertNil(h.tbr(0.8, minutes: 30))
        let tbr = try XCTUnwrap(h.state.tempBasals.last)
        XCTAssertEqual(tbr.schedule?.hourlyRates[11], 1.5)

        // the schedule is edited afterwards; the dose must still be costed with the snapshot
        let reported = DoseFactory.tempBasalDose(tbr, mutable: false, insulinType: nil, endDate: tbr.plannedEnd)
        // 10 min at 50% of 0.5 + 5 min at 50% of 1.5
        let firstPart: Double = 0.5 * 0.5 * (10.0 / 60.0)
        let secondPart: Double = 0.5 * 1.5 * (5.0 / 60.0)
        XCTAssertEqual(reported.deliveredUnits ?? 0, firstPart + secondPart, accuracy: 0.001)
        let averageScheduled: Double = (0.5 * 10.0 + 1.5 * 5.0) / 15.0
        XCTAssertEqual(
            reported.scheduledBasalRate?.doubleValue(for: DoseEntry.unitsPerHour) ?? 0,
            averageScheduled,
            accuracy: 1E-9
        )
    }

    func testAccountingPerSegment() {
        let schedule = InsightBasalSchedule(hourlyRates: (0 ..< 24).map { $0 < 11 ? 0.5 : 1.5 })!
        let result = TempBasalAccounting.account(
            percent: 50, start: date("2026-11-18T10:50:00Z"), end: date("2026-11-18T11:05:00Z"), schedule: schedule, utcOffset: 0,
            fallbackRate: 9
        )
        XCTAssertEqual(result.deliveredUnits, 0.104, accuracy: 0.001)
        let expectedAverage: Double = (0.5 * 10.0 + 1.5 * 5.0) / 15.0
        XCTAssertEqual(result.averageScheduledRate, expectedAverage, accuracy: 1E-9)
    }

    func testHistoryUsesTheSnapshotNotTheCurrentSchedule() throws {
        let old = InsightBasalSchedule(hourlyRates: Array(repeating: 1.0, count: 24))!
        let new = InsightBasalSchedule(hourlyRates: Array(repeating: 3.0, count: 24))!
        let tbr = ActiveTempBasal(
            percent: 150,
            durationMinutes: 30,
            start: date("2026-11-18T10:00:00Z"),
            scheduledRate: 1.0,
            effectiveRate: 1.5,
            decisionId: nil,
            automatic: true,
            endedAt: nil,
            schedule: old,
            utcOffsetSeconds: 0
        )
        let ctx = HistoryMappingContext(
            serial: "S",
            schedule: new,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            insulinType: nil,
            bolus: nil,
            tempBasals: [tbr]
        )
        let e = HistoryEvent(
            seq: 1,
            time: date("2026-11-18T10:30:00Z"),
            type: "tbrEnd",
            data: json(#"{"percent":150,"duration":30}"#)
        )
        let dose = try XCTUnwrap(HistoryMapper.map([e], context: ctx).events.first?.dose)
        XCTAssertEqual(dose.unitsPerHour, 1.5, accuracy: 1E-9, "1.5 U/h from the snapshot, not 4.5 from the edited schedule")
    }

    func testLateEventsUseTheScheduleThatWasActiveAtTheTime() throws {
        let old = InsightBasalSchedule(hourlyRates: Array(repeating: 1.0, count: 24))!
        let new = InsightBasalSchedule(hourlyRates: Array(repeating: 3.0, count: 24))!
        var ctx = HistoryMappingContext(
            serial: "S",
            schedule: new,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            insulinType: nil,
            bolus: nil
        )
        ctx.scheduleRevisions = [
            ScheduleRevision(effectiveFrom: date("2026-11-18T00:00:00Z"), schedule: old),
            ScheduleRevision(effectiveFrom: date("2026-11-18T12:00:00Z"), schedule: new)
        ]
        let e = HistoryEvent(
            seq: 1,
            time: date("2026-11-18T10:30:00Z"),
            type: "tbrEnd",
            data: json(#"{"percent":150,"duration":30}"#)
        )
        XCTAssertEqual(try XCTUnwrap(HistoryMapper.map([e], context: ctx).events.first?.dose).unitsPerHour, 1.5, accuracy: 1E-9)
    }

    func testScheduleRevisionIsRecordedWhenTheProfileIsSynced() {
        let h = ManagerHarness()
        let before = h.state.scheduleRevisions.count
        guard case .success = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 0.9)]) else { return XCTFail() }
        // the previous schedule is kept (for old events) and the new one added
        XCTAssertEqual(h.state.scheduleRevisions.count, before + 2)
        XCTAssertEqual(h.state.scheduleRevisions.first?.schedule.hourlyRates[0], 1.0)
        XCTAssertEqual(h.state.scheduleRevisions.last?.schedule.hourlyRates[0], 0.9)
    }
}

// MARK: - H3

final class H3UnreadableFieldsTests: XCTestCase {
    private func decode(_ string: String) throws -> BridgeStatus { try BridgeJSON.decode(BridgeStatus.self, from: json(string)) }

    func testUndecodableTbrAndBolusesAreUnknownNotEmpty() throws {
        let tbr = try decode(#"{"tbr":{"percent":"lots","duration":30},"boluses":[]}"#)
        XCTAssertTrue(tbr.tbrIsUnreadable)
        XCTAssertNil(tbr.tbr)
        XCTAssertFalse(tbr.bolusesAreUnreadable)

        let boluses = try decode(#"{"tbr":null,"boluses":[{"bolusId":"x","amount":1,"remaining":0}]}"#)
        XCTAssertTrue(boluses.bolusesAreUnreadable)
        XCTAssertFalse(boluses.tbrIsUnreadable)

        let garbage = try decode(#"{"tbr":"nope","boluses":"nope"}"#)
        XCTAssertTrue(garbage.tbrIsUnreadable)
        XCTAssertTrue(garbage.bolusesAreUnreadable)
    }

    func testNullAndEmptyStillMeanNothingIsRunning() throws {
        let status = try decode(#"{"tbr":null,"boluses":[]}"#)
        XCTAssertFalse(status.tbrIsUnreadable)
        XCTAssertFalse(status.bolusesAreUnreadable)
        let missing = try decode("{}")
        XCTAssertFalse(missing.tbrIsUnreadable)
        XCTAssertFalse(missing.bolusesAreUnreadable)
        // one broken element makes the whole list unknown (never trust half of it)
        XCTAssertTrue(try decode(#"{"boluses":[{"bolusId":1,"amount":1,"remaining":0},{"bolusId":"bad"}]}"#).bolusesAreUnreadable)
    }

    func testUnreadableBolusListDoesNotEndOrAdoptABolus() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        // every status from now on has an unparseable `boluses` field
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(5000), boluses: [], bolusesAreUnreadable: true)
        h.advance(100)
        h.ensureData()
        h.advance(100)
        h.ensureData()
        let bolus = try XCTUnwrap(h.state.bolus)
        XCTAssertEqual(bolus.phase, .inProgress, "unknown is not 'finished'")
        XCTAssertEqual(bolus.missCount, 0)
    }

    func testUnreadableBolusListNeverAdoptsAnExternalBolus() {
        let h = ManagerHarness()
        h.client.status = BridgeStatus(
            timestamp: h.now.addingTimeInterval(5),
            boluses: [.init(bolusId: 3, type: nil, amount: 1, remaining: 0.5)],
            bolusesAreUnreadable: true
        )
        h.ensureData()
        XCTAssertNil(h.state.bolus)
    }

    func testUnreadableTbrDoesNotEndARunningTbr() throws {
        let h = ManagerHarness()
        h.client.status = h.status(tbr: runningTbr(h))
        h.ensureData()
        h.advance(100)
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(5), tbrIsUnreadable: true)
        h.ensureData()
        XCTAssertNil(h.state.tempBasals.last?.endedAt, "an unparseable tbr field is not 'no TBR'")
        XCTAssertNotNil(h.state.runningTempBasal(at: h.now))
    }

    func testResolverIsUndecidedWhenTheRelevantFieldIsUnreadable() {
        let sent = Date()
        func cmd(_ kind: PendingCommand.Kind, units: Double? = nil, percent: Int? = nil) -> PendingCommand {
            PendingCommand(
                kind: kind,
                requestId: "r",
                sentDate: sent,
                baselineSequence: nil,
                units: units,
                percent: percent,
                durationMinutes: 30,
                scheduledRate: 1,
                decisionId: nil,
                automatic: true,
                insulinType: nil,
                isUncertain: true
            )
        }
        let late = sent.addingTimeInterval(120)
        let noBolus = BridgeStatus(timestamp: late, bolusesAreUnreadable: true)
        let noTbr = BridgeStatus(timestamp: late, tbrIsUnreadable: true)
        XCTAssertEqual(
            UncertaintyResolver.decide(command: cmd(.bolus, units: 1), status: noBolus, history: [], historyComplete: true),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver.decide(command: cmd(.setTBR, percent: 120), status: noTbr, history: [], historyComplete: true),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver.decide(command: cmd(.cancelTBR), status: noTbr, history: [], historyComplete: true),
            .undecided
        )
        // readable fields at the same time stamp do decide
        XCTAssertEqual(
            UncertaintyResolver
                .decide(
                    command: cmd(.bolus, units: 1),
                    status: BridgeStatus(timestamp: late),
                    history: [],
                    historyComplete: true
                ),
            .notDelivered
        )
    }
}

// MARK: - H4 / hello

final class ProtocolVersionTests: XCTestCase {
    func testVersionIsTwo() {
        XCTAssertEqual(BridgeProtocol.version, 2)
    }

    func testBridgeWithAnotherProtocolIsIncompatible() {
        for reply in [
            #"{"protocol":1,"bridgeVersion":"old","pumpPaired":true}"#,
            #"{"bridgeVersion":"none","pumpPaired":true}"#,
            #"{"protocol":3,"pumpPaired":true}"#
        ] {
            let t = SessionTestCase()
            t.setUp()
            t.bridge.helloReply = .ok(json(reply))
            t.connect()
            XCTAssertEqual(t.session.state, .incompatible, reply)
            XCTAssertEqual(t.link.state, .stopped)
            t.tearDown()
        }
    }

    func testSessionStartUsesVersionTwo() {
        let t = SessionTestCase()
        t.setUp()
        t.connect()
        let start = t.link.sent.compactMap { HandshakeMessage.decode($0) }.first { $0["t"] as? String == "sessionStart" }
        XCTAssertEqual(start?["v"] as? Int, 2)
        t.tearDown()
    }
}

// MARK: - M1

final class M1RequestOutcomeTests: XCTestCase {
    private func outcome(
        _ state: RequestOutcomeState,
        result: String? = nil,
        error: BridgeRemoteError? = nil
    ) -> BridgeResult<RequestOutcomeResult> {
        .success(RequestOutcomeResult(state: state, result: result.map(json), error: error, completedAt: nil))
    }

    func testOutcomeDecoding() throws {
        let ok = try BridgeJSON.decode(
            RequestOutcomeResult.self,
            from: json(
                #"{"state":"succeeded","result":{"bolusId":9,"amount":1.0},"error":null,"completedAt":"2026-11-18T10:00:00Z"}"#
            )
        )
        XCTAssertEqual(ok.state, .succeeded)
        XCTAssertEqual(ok.result?["bolusId"]?.intValue, 9)
        XCTAssertNotNil(ok.completedAt)
        let failed = try BridgeJSON.decode(
            RequestOutcomeResult.self,
            from: json(#"{"state":"failed","error":{"code":"pumpSuspended","message":"x","uncertain":false}}"#)
        )
        XCTAssertEqual(failed.error?.code, .pumpSuspended)
        for raw in ["unknown", "inProgress", "uncertain"] {
            XCTAssertEqual(
                try BridgeJSON.decode(RequestOutcomeResult.self, from: json(#"{"state":"\#(raw)"}"#)).state.rawValue,
                raw
            )
        }
        XCTAssertEqual(try BridgeJSON.decode(RequestOutcomeResult.self, from: json(#"{"state":"somethingNew"}"#)).state, .unknown)
        XCTAssertEqual(try BridgeJSON.decode(RequestOutcomeResult.self, from: json(#"{"state":5}"#)).state, .unknown)
        XCTAssertEqual(try BridgeJSON.decode(RequestOutcomeResult.self, from: json("{}")).state, .unknown)
    }

    func testRequestIsEncodedAsRequestIdArgs() throws {
        XCTAssertEqual(BridgeOp.getRequestOutcome.rawValue, "getRequestOutcome")
        XCTAssertFalse(BridgeOp.getRequestOutcome.isDosing, "a query is never a dosing command")
        let t = SessionTestCase()
        t.setUp()
        t.bridge.handler = { op, _ in
            op == "getRequestOutcome" ? .ok(json(#"{"state":"inProgress"}"#)) : .ok(.object([:]))
        }
        t.connect()
        let client = SessionBridgeClient(session: t.session)
        var result: BridgeResult<RequestOutcomeResult>?
        client.getRequestOutcome(requestId: "abc") { result = $0 }
        t.flush()
        XCTAssertEqual(try result?.get().state, .inProgress)
        XCTAssertEqual(t.bridge.requests.last?.args, json(#"{"requestId":"abc"}"#))
        t.tearDown()
    }

    func testSucceededIsAuthoritativeEvenWithAStaleStatus() throws {
        let h = ManagerHarness()
        let decision = UUID()
        h.client.bolusResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.bolus(1.0, decision: decision)))
        h.client.status = h.status(after: -500) // useless evidence
        h.client.outcomeResult = outcome(.succeeded, result: #"{"bolusId":9,"amount":1.0}"#)
        h.advance(6)
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertEqual(h.client.outcomeCalls, [h.client.deliverBolusCalls[0].requestId])
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1, "never resent")
        let bolus = try XCTUnwrap(h.state.bolus)
        XCTAssertEqual(bolus.bolusId, 9)
        XCTAssertEqual(bolus.decisionId, decision)
    }

    func testFailedIsAuthoritativeNotDelivered() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.status = h.status(after: -500)
        h.client.outcomeResult = outcome(.failed, error: BridgeRemoteError(code: .pumpUnreachable, message: "", uncertain: false))
        h.advance(6)
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertNil(h.state.bolus)
        XCTAssertEqual(h.delegate.eventBatches.last?.compactMap(\.dose).count, 0, "the assumed dose is dropped")
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
    }

    func testFailedButUncertainFallsBackToEvidence() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.outcomeResult = outcome(.failed, error: BridgeRemoteError(code: .internal, message: "", uncertain: true))
        h.client.status = h.status(after: -500)
        h.advance(6)
        XCTAssertTrue(h.state.isDeliveryUncertain, "stale evidence cannot settle it")
    }

    func testInProgressWaitsAndAsksAgainWithBackoffNeverResends() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.outcomeResult = outcome(.inProgress)
        let statusCallsBefore = h.client.statusCalls
        h.advance(6) // first query at +5 s
        XCTAssertEqual(h.client.outcomeCalls.count, 1)
        h.advance(4)
        XCTAssertEqual(h.client.outcomeCalls.count, 1, "backoff 5 s")
        h.advance(2) // +5 s after the first answer
        XCTAssertEqual(h.client.outcomeCalls.count, 2)
        h.advance(9)
        XCTAssertEqual(h.client.outcomeCalls.count, 2, "backoff 10 s")
        h.advance(2)
        XCTAssertEqual(h.client.outcomeCalls.count, 3)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
        XCTAssertEqual(h.client.statusCalls, statusCallsBefore, "no evidence path while the bridge is still working")

        h.client.outcomeResult = outcome(.succeeded, result: #"{"bolusId":4,"amount":1.0}"#)
        h.advance(25)
        XCTAssertFalse(h.state.isDeliveryUncertain)
    }

    func testUnknownUsesEvidenceButNeedsAnAgedConnectedStatus() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.outcomeResult = outcome(.unknown)
        // a status only 30 s after the command: too early to prove that nothing happened
        h.client.status = h.status(after: 30)
        h.advance(6)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        // old enough, but the pump is not connected to the bridge
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(100), pumpLink: .disconnected, serial: "SN1")
        h.advance(61)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        // old enough and connected
        h.client.status = h.status(after: 100)
        h.advance(61)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
    }

    func testUncertainOutcomeStateFallsBackToEvidence() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.outcomeResult = outcome(.uncertain)
        h.client.status = h.status(after: 100, boluses: [.init(bolusId: 8, type: nil, amount: 1.0, remaining: 0.5)])
        h.advance(6)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        XCTAssertEqual(h.state.bolus?.bolusId, 8, "positive evidence still adopts a running bolus")
    }

    func testUnreachableBridgeKeepsTheCommandUncertain() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.outcomeResult = .failure(.notConnected)
        h.advance(6)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        h.client.outcomeResult = outcome(.failed, error: BridgeRemoteError(code: .pumpSuspended, message: "", uncertain: false))
        h.advance(61)
        XCTAssertFalse(h.state.isDeliveryUncertain)
    }

    func testSucceededTbrIsAdoptedFromTheOutcome() throws {
        let h = ManagerHarness()
        let decision = UUID()
        h.client.tbrResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.tbr(1.5, decision: decision)))
        h.client.outcomeResult = outcome(.succeeded, result: #"{"percent":150,"duration":30}"#)
        h.client.status = h.status(after: -100)
        h.advance(6)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        let tbr = try XCTUnwrap(h.state.tempBasals.last)
        XCTAssertEqual(tbr.percent, 150)
        XCTAssertEqual(tbr.decisionId, decision)
        XCTAssertNotNil(tbr.schedule)
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
    }

    func testSuspendOutcomes() {
        let h = ManagerHarness()
        h.client.modeResult = .failure(.timeout)
        _ = h.suspend()
        h.client.outcomeResult = outcome(.succeeded, result: #"{"mode":"stopped"}"#)
        h.client.status = h.status(after: 100, mode: .stopped)
        h.advance(6)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        XCTAssertTrue(h.state.isSuspended)
        XCTAssertEqual(h.client.modeCalls.count, 1)
    }
}

// MARK: - M2

final class M2StatusOrderingTests: XCTestCase {
    func testOlderStatusIsIgnored() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 100, mode: .stopped)
        h.ensureData()
        XCTAssertTrue(h.state.isSuspended)
        let applied = h.state.lastPumpReadDate

        h.advance(70)
        h.client.status = h.status(after: 10, mode: .started, reservoir: 7, serial: "OTHER") // read before the applied one
        h.ensureData()
        XCTAssertTrue(h.state.isSuspended, "older read must not undo newer knowledge")
        XCTAssertEqual(h.state.pumpSerial, "SN1")
        XCTAssertEqual(h.state.reservoirUnits, 100)
        XCTAssertEqual(h.state.lastPumpReadDate, applied)
    }

    func testFinalizedBolusIsNeverAdoptedAgain() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.advance(60)
        h.client.status = h.status(after: 1, historySequence: 101)
        h.client
            .history =
            [
                h
                    .historyEvent(
                        101,
                        "bolusDelivered",
                        after: -10,
                        #"{"bolusId":7,"bolusType":"standard","programmed":1.0,"delivered":1.0}"#
                    )
            ]
        h.ensureData()
        XCTAssertNil(h.state.bolus)
        XCTAssertTrue(h.state.finalizedBolusIds.contains(7))

        h.advance(70)
        // a newer status that still lists the (long finished) bolus
        h.client.status = h.status(
            after: 5,
            boluses: [.init(bolusId: 7, type: nil, amount: 1.0, remaining: 0.4)],
            historySequence: 101
        )
        h.ensureData()
        XCTAssertNil(h.state.bolus, "bolus 7 is already accounted for")
        XCTAssertEqual(h.manager.status.bolusState, .noBolus)
        XCTAssertEqual(
            h.delegate.eventBatches.last?.compactMap(\.dose).filter { $0.type == .bolus && $0.isMutable }.count,
            0,
            "nothing in progress is reported any more"
        )
    }

    func testAUnknownBolusIsStillAdopted() {
        let h = ManagerHarness()
        h.client.status = h.status(boluses: [.init(bolusId: 41, type: nil, amount: 2.0, remaining: 1.0)])
        h.ensureData()
        XCTAssertEqual(h.state.bolus?.bolusId, 41)
    }
}

// MARK: - M3

final class M3BolusFinishTests: XCTestCase {
    func testOneMissIsNotEnoughTwoConsecutiveMissesAre() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.client.status = h.status(after: 5)
        h.advance(61) // bolus watch: first status without the bolus
        XCTAssertEqual(try XCTUnwrap(h.state.bolus).phase, .inProgress)
        XCTAssertEqual(h.state.bolus?.missCount, 1)

        // the bolus shows up again: the counter starts over
        h.client.status = h.status(after: 5, boluses: [.init(bolusId: 7, type: nil, amount: 1.0, remaining: 0.5)])
        h.advance(61)
        XCTAssertEqual(h.state.bolus?.missCount, 0)

        h.client.status = h.status(after: 5)
        h.advance(61)
        XCTAssertEqual(h.state.bolus?.phase, .inProgress)
        h.advance(61)
        XCTAssertEqual(h.state.bolus?.phase, .finished)
    }

    func testCancelStillSendsAfterASingleMiss() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(2.0))
        h.client.status = h.status(after: 5)
        h.advance(61)
        XCTAssertEqual(h.state.bolus?.missCount, 1)
        h.client.cancelBolusResult = .success(CancelBolusResult(delivered: 0.6))
        guard case let .success(dose?) = h.cancelBolus() else { return XCTFail() }
        XCTAssertEqual(h.client.cancelBolusIds, [7])
        XCTAssertEqual(dose.deliveredUnits, 0.6)
    }

    func testCancelSendsWhenTheBolusWasMarkedFinishedButIsInsideItsPlannedDelivery() {
        let h = ManagerHarness()
        let planned = UnfinalizedBolus(
            requestId: "r", units: 5.0, startDate: h.now.addingTimeInterval(-10), bolusId: 5, decisionId: nil, automatic: false,
            insulinType: nil, deliveredUnits: 5.0, phase: .finished, endDate: h.now, programmedOnPump: false
        )
        h.queue.sync { h.manager.mutate { $0.bolus = planned } }
        guard case .success = h.cancelBolus() else { return XCTFail() }
        XCTAssertEqual(h.client.cancelBolusIds, [5], "a 5 U bolus is still being delivered 10 s after it started")
    }

    func testCancelIsANoOpWhenTheBolusCannotStillBeRunning() {
        let h = ManagerHarness()
        let old = UnfinalizedBolus(
            requestId: "r", units: 1.0, startDate: h.now.addingTimeInterval(-3600), bolusId: 5, decisionId: nil, automatic: false,
            insulinType: nil, deliveredUnits: 1.0, phase: .finished, endDate: h.now.addingTimeInterval(-3500),
            programmedOnPump: false
        )
        h.queue.sync { h.manager.mutate { $0.bolus = old } }
        guard case let .success(dose) = h.cancelBolus() else { return XCTFail() }
        XCTAssertNil(dose)
        XCTAssertTrue(h.client.cancelBolusIds.isEmpty)
    }

    func testStatusReadBeforeTheBridgeAcceptedTheBolusIsNoMiss() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.queue.sync { h.manager.mutate { st in st.bolus?.acceptedAt = h.now.addingTimeInterval(500) } }
        h.advance(61)
        h.client.status = h.status(after: 5) // read at +66 s, before the (future) acceptance time
        h.advance(61)
        XCTAssertEqual(h.state.bolus?.missCount, 0)
        XCTAssertEqual(h.state.bolus?.phase, .inProgress)
    }

    func testFallbackFinishesALongOverdueBolusEvenWithoutTimestamps() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.client.status = BridgeStatus(timestamp: nil) // no usable timestamp at all
        h.advance(10 * 60)
        h.ensureData()
        XCTAssertEqual(h.state.bolus?.phase, .finished)
    }
}

// MARK: - M4

final class M4SyncIdentifierTests: XCTestCase {
    func testLateHistoryEventForALocallyFinalizedBolusReusesItsIdentifier() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.client.status = h.status(after: 5)
        h.advance(61)
        h.advance(61) // finished (two misses)
        XCTAssertEqual(h.state.bolus?.phase, .finished)

        h.advance(12 * 60) // past the grace period: finalized locally
        h.ensureData()
        XCTAssertNil(h.state.bolus)
        XCTAssertEqual(h.state.finalizedLocal.count, 1)
        let local = try XCTUnwrap(h.delegate.allEvents.last { $0.dose?.type == .bolus && $0.dose?.isMutable == false })

        // the history finally delivers the event
        h.advance(120)
        h.client.status = h.status(after: 5, historySequence: 101)
        h.client
            .history =
            [
                h
                    .historyEvent(
                        101,
                        "bolusDelivered",
                        after: -800,
                        #"{"bolusId":7,"bolusType":"standard","programmed":1.0,"delivered":1.0}"#
                    )
            ]
        h.ensureData()

        let finals = h.delegate.allEvents.filter { $0.dose?.type == .bolus && $0.dose?.isMutable == false }
        XCTAssertGreaterThanOrEqual(finals.count, 2)
        XCTAssertEqual(
            Set(finals.map(\.raw)).count,
            1,
            "one dose, one sync identifier: LoopKit replaces instead of double counting"
        )
        XCTAssertEqual(finals.last?.raw, local.raw)
        XCTAssertTrue(h.state.finalizedLocal.isEmpty, "confirmed by the history")
        XCTAssertEqual(finals.last?.dose?.wasProgrammedByPumpUI, false)
    }

    func testLateHistoryEventForALocallyFinalizedTempBasalReusesItsIdentifier() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5, minutes: 30))
        let start = h.state.tempBasals[0].start
        h.advance(31 * 60)
        h.advance(12 * 60)
        h.client.status = h.status(after: 1)
        h.ensureData()
        XCTAssertTrue(h.state.tempBasals.isEmpty)
        XCTAssertEqual(h.state.finalizedLocal.count, 1)
        let local = try XCTUnwrap(h.delegate.allEvents.last { $0.dose?.type == .tempBasal && $0.dose?.isMutable == false })

        h.advance(120)
        h.client.status = h.status(after: 5, historySequence: 101)
        h.client
            .history =
            [HistoryEvent(
                seq: 101,
                time: start.addingTimeInterval(30 * 60),
                type: "tbrEnd",
                data: json(#"{"percent":150,"duration":30}"#)
            )]
        h.ensureData()
        let finals = h.delegate.allEvents.filter { $0.dose?.type == .tempBasal && $0.dose?.isMutable == false }
        XCTAssertEqual(Set(finals.map(\.raw)).count, 1)
        XCTAssertEqual(finals.last?.raw, local.raw)
        XCTAssertTrue(h.state.finalizedLocal.isEmpty)
    }

    func testSharedKeysBetweenLocalAndHistory() {
        let b = UnfinalizedBolus(
            requestId: "r",
            units: 1,
            startDate: Date(),
            bolusId: 12,
            decisionId: nil,
            automatic: false,
            insulinType: nil,
            deliveredUnits: 0,
            phase: .inProgress,
            endDate: nil,
            programmedOnPump: false
        )
        XCTAssertEqual(b.syncKey(serial: "S"), "insight:S:bolus:12")
        var noId = b
        noId.bolusId = nil
        XCTAssertEqual(noId.syncKey(serial: "S"), "insight-local:S:bolus:r")
        let e = HistoryEvent(
            seq: 5,
            time: Date(),
            type: "bolusDelivered",
            data: json(#"{"bolusId":12,"programmed":1.0,"delivered":1.0}"#)
        )
        let ctx = HistoryMappingContext(serial: "S", schedule: nil, timeZone: .current, insulinType: nil, bolus: nil)
        XCTAssertEqual(
            HistoryMapper.map([e], context: ctx).events.first?.raw,
            Data("insight:S:bolus:12".utf8),
            "history uses the same key even if unseen before"
        )
    }

    func testFinalizedLocalRecordsAreBounded() {
        let h = ManagerHarness()
        h.queue.sync {
            h.manager.mutate { st in
                for i in 0 ..< 60 {
                    st.finalizedLocal
                        .append(FinalizedLocalDose(
                            kind: .bolus,
                            key: "k\(i)",
                            start: h.now,
                            end: h.now,
                            bolusId: i,
                            units: 1,
                            percent: nil,
                            finalizedAt: h.now
                        ))
                }
            }
        }
        h.ensureData()
        XCTAssertLessThanOrEqual(h.state.finalizedLocal.count, 30)
    }
}

// MARK: - M5

final class M5NumericRobustnessTests: XCTestCase {
    func testExactIntNeverTraps() {
        XCTAssertNil(Double(1E300).exactInt)
        XCTAssertNil(Double.nan.exactInt)
        XCTAssertNil(Double.infinity.exactInt)
        XCTAssertNil(Double(120.5).exactInt)
        XCTAssertEqual(Double(120).exactInt, 120)
        XCTAssertEqual(json("1e300").intValue, nil)
        XCTAssertEqual(Double.nan.clampedInt, 0)
        XCTAssertEqual(Double(1E300).clampedInt, 1_000_000_000_000)
        XCTAssertEqual(Date(timeIntervalSince1970: 1E300).epochSeconds, 1_000_000_000_000)
    }

    func testHistoryEventsWithAbsurdNumbersDoNotCrash() {
        let huge = "1e300"
        let events = [
            HistoryEvent(
                seq: 1,
                time: date("2026-11-18T10:00:00Z"),
                type: "tbrEnd",
                data: json(#"{"percent":\#(huge),"duration":\#(huge)}"#)
            ),
            HistoryEvent(
                seq: 2,
                time: date("2026-11-18T10:00:00Z"),
                type: "bolusDelivered",
                data: json(#"{"bolusId":\#(huge),"programmed":\#(huge),"delivered":\#(huge)}"#)
            ),
            HistoryEvent(
                seq: 3,
                time: date("2026-11-18T10:00:00Z"),
                type: "alert",
                data: json(#"{"alertId":\#(huge),"alertType":"E1"}"#)
            ),
            HistoryEvent(seq: 4, time: date("2026-11-18T10:00:00Z"), type: "tbrStart", data: json(#"{"percent":\#(huge)}"#)),
            HistoryEvent(
                seq: 5,
                time: date("2026-11-18T10:00:00Z"),
                type: "tbrEnd",
                data: json(#"{"percent":-5,"duration":-1}"#)
            ),
            HistoryEvent(
                seq: 6,
                time: date("2026-11-18T10:00:00Z"),
                type: "tbrEnd",
                data: json(#"{"percent":120.5,"duration":30}"#)
            ),
            HistoryEvent(
                seq: 7,
                time: date("2026-11-18T10:00:00Z"),
                type: "bolusDelivered",
                data: json(#"{"bolusId":-1e300,"programmed":"x","delivered":null}"#)
            )
        ]
        let ctx = HistoryMappingContext(
            serial: "S",
            schedule: ManagerHarness.flatSchedule(),
            timeZone: .current,
            insulinType: nil,
            bolus: nil
        )
        let result = HistoryMapper.map(events, context: ctx)
        XCTAssertEqual(result.events.count, events.count - 0)
        XCTAssertTrue(
            result.events.compactMap(\.dose)
                .allSatisfy { ($0.deliveredUnits ?? 0) <= HistoryMapper.maxPlausibleBolus || $0.type != .bolus }
        )
        XCTAssertTrue(result.unreadableSequences.contains(1))
        XCTAssertTrue(result.unreadableSequences.contains(2))
        XCTAssertTrue(result.unreadableSequences.contains(5))
        XCTAssertTrue(result.unreadableSequences.contains(6))
        XCTAssertTrue(result.unreadableSequences.contains(7))
    }

    func testTempBasalConversionWithAbsurdInput() throws {
        XCTAssertEqual(
            try TempBasalConverter.plan(requestedRate: 1E300, scheduledRate: 1.0, duration: 1E300),
            .set(percent: 250, durationMinutes: 1440, effectiveRate: 2.5)
        )
        XCTAssertThrowsError(try TempBasalConverter.plan(requestedRate: 1E300, scheduledRate: 1E-300, duration: 1E300))
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(1E300), 1440)
        XCTAssertEqual(TempBasalConverter.normalizedDurationMinutes(.greatestFiniteMagnitude), 1440)
        XCTAssertThrowsError(
            try TempBasalConverter
                .plan(requestedRate: .greatestFiniteMagnitude, scheduledRate: 0, duration: 1800)
        )
        let sched = ManagerHarness.flatSchedule(1.0)
        XCTAssertNoThrow(
            try TempBasalConverter
                .plan(requestedRate: 1E300, schedule: sched, at: Date(), utcOffset: 0, duration: 1E300)
        )
        XCTAssertEqual(sched.rateSegments(from: Date(timeIntervalSince1970: .nan), to: Date(), utcOffset: 0), [])
    }

    func testBasalScheduleWithAbsurdStartTimesThrows() {
        let items = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: .nan, value: 1.0)]
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: items))
        let huge = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 1E300, value: 1.0)]
        XCTAssertThrowsError(try InsightBasalSchedule.validated(items: huge))
    }

    func testHugeValuesInAStatusAreHarmless() {
        let h = ManagerHarness()
        h.client.status = BridgeStatus(
            timestamp: h.now.addingTimeInterval(5), serial: "SN1", battery: .init(percent: 1E300),
            reservoir: .init(units: 1E300, cartridgeType: nil),
            basal: .init(activeProfile: 1, rate: 1E300),
            tbr: .init(percent: Int.max, duration: Int.max, remaining: Int.min, start: nil),
            pumpTime: .init(utc: h.now, pumpLocal: "9999-99-99T99:99:99", driftSeconds: 1E300)
        )
        h.ensureData()
        XCTAssertTrue(h.state.tempBasals.isEmpty, "an impossible TBR is not recorded")
        XCTAssertEqual(h.state.batteryPercent, 100)
        XCTAssertNoThrow(h.manager.needsTimeSync)
    }

    func testResolverDoesNotTrapOnHugeEventNumbers() {
        let sent = Date()
        let cmd = PendingCommand(
            kind: .setTBR,
            requestId: "r",
            sentDate: sent,
            baselineSequence: nil,
            units: nil,
            percent: 120,
            durationMinutes: 30,
            scheduledRate: 1,
            decisionId: nil,
            automatic: true,
            insulinType: nil,
            isUncertain: true
        )
        let e = HistoryEvent(seq: 1, time: sent, type: "tbrStart", data: json(#"{"percent":1e300}"#))
        XCTAssertEqual(
            UncertaintyResolver
                .decide(
                    command: cmd,
                    status: BridgeStatus(timestamp: sent.addingTimeInterval(10)),
                    history: [e],
                    historyComplete: true
                ),
            .undecided
        )
    }

    func testAbsurdHistoryThroughTheWholePipelineIsNotACrashLoop() {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 103)
        h.client.history = [
            h.historyEvent(101, "tbrEnd", after: -10, #"{"percent":1e300,"duration":1e300}"#),
            h.historyEvent(102, "bolusDelivered", after: -9, #"{"bolusId":1e300,"programmed":1e300,"delivered":1e300}"#),
            h.historyEvent(103, "cannulaFilled", after: -8, #"{"units":0.5}"#)
        ]
        for _ in 0 ..< 3 {
            h.advance(120)
            h.ensureData() // repeated: a bad event must not wedge or crash anything
        }
        XCTAssertEqual(h.state.lastHistorySequence, 100, "history is not advanced past the unreadable events")
        XCTAssertEqual(
            h.delegate.allEvents.filter { $0.type == .prime }.count,
            3,
            "later events are still reported (deduplicated by identifier)"
        )
        XCTAssertEqual(Set(h.delegate.allEvents.filter { $0.type == .prime }.map(\.raw)).count, 1)
    }
}

// MARK: - M6 / M7

final class M6M7TempBasalTests: XCTestCase {
    func testTbrIsRecordedAsTheBridgeReportsItAndMismatchIsSurfaced() async throws {
        let h = ManagerHarness()
        h.client.tbrResult = .success(SetTBRResult(percent: 200, duration: 45))
        let statusCalls = h.client.statusCalls
        XCTAssertNil(h.tbr(1.5, minutes: 30))
        let tbr = try XCTUnwrap(h.state.tempBasals.last)
        XCTAssertEqual(tbr.percent, 200, "what the pump reports, even if it is more than asked")
        XCTAssertEqual(tbr.durationMinutes, 45)
        XCTAssertEqual(tbr.effectiveRate, 2.0, accuracy: 1E-9)
        XCTAssertGreaterThan(h.client.statusCalls, statusCalls + 1, "the status is re-read")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            h.delegate.issuedAlerts
                .contains { $0.identifier.alertIdentifier == InsightAlertCatalog.tbrMismatchAlertIdentifier }
        )
    }

    func testMatchingReportCausesNoAlert() async throws {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5, minutes: 30))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            h.delegate.issuedAlerts
                .contains { $0.identifier.alertIdentifier == InsightAlertCatalog.tbrMismatchAlertIdentifier }
        )
    }

    func testCancelBranchConsultsTheBridgeStatus() {
        // our record says the TBR is over, the bridge still reports one
        let h = ManagerHarness()
        h.client.status = h
            .status(tbr: BridgeStatus.TBR(percent: 150, duration: 30, remaining: 5, start: h.now.addingTimeInterval(-40 * 60)))
        h.ensureData()
        XCTAssertNil(h.state.runningTempBasal(at: h.now), "by our clock it should be over")
        XCTAssertNotNil(h.client.status.tbr)
        h.advance(70)
        h.client.status = h
            .status(tbr: BridgeStatus.TBR(percent: 150, duration: 30, remaining: 5, start: h.now.addingTimeInterval(-40 * 60)))
        XCTAssertNil(h.tbr(1.0)) // = scheduled rate -> cancel plan
        XCTAssertEqual(h.client.cancelTbrCalls, 1, "the bridge reported a TBR, so it is cancelled")
    }

    func testCancelBranchCancelsWhenTheTbrFieldWasUnreadable() {
        let h = ManagerHarness()
        h.client.status = BridgeStatus(
            timestamp: h.now.addingTimeInterval(5),
            basal: .init(activeProfile: 1, rate: 1.0),
            tbrIsUnreadable: true
        )
        XCTAssertNil(h.tbr(1.0))
        XCTAssertEqual(h.client.cancelTbrCalls, 1, "unknown is treated as possibly running")
    }

    func testZeroDurationCancelAlsoConsultsTheStatus() {
        let h = ManagerHarness()
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(5), tbrIsUnreadable: true)
        h.ensureData()
        XCTAssertNil(h.tbr(0, minutes: 0))
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
    }
}

// MARK: - M8

final class M8UnreadableHistoryTests: XCTestCase {
    func testUnreadableBolusIsCountedAndTheSequenceDoesNotMovePastIt() async throws {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 103)
        let good = h.historyEvent(101, "tubeFilled", after: -10, #"{"units":5}"#)
        let afterwards = h.historyEvent(103, "cannulaFilled", after: -5, #"{"units":0.5}"#)
        h.client.historyResult = .success(HistoryResult(
            events: [good, afterwards], lastSequence: 103, more: false,
            unreadable: [UnreadableHistoryEvent(
                seq: 102,
                typeName: "bolusDelivered",
                time: h.now.addingTimeInterval(-8),
                programmed: 2.5
            )]
        ))
        h.ensureData()

        XCTAssertEqual(h.state.lastHistorySequence, 101, "stops right before the unreadable event")
        let bolus = try XCTUnwrap(h.delegate.allEvents.compactMap(\.dose).first { $0.type == .bolus })
        XCTAssertEqual(bolus.deliveredUnits, 2.5, "the programmed amount counts as delivered")
        XCTAssertFalse(bolus.isMutable)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            h.delegate.issuedAlerts
                .filter { $0.identifier.alertIdentifier == InsightAlertCatalog.unreadableHistoryAlertIdentifier }.count,
            1
        )
        XCTAssertTrue(h.state.unreadableHistoryAlertIssued)

        // read again: still unreadable, same identifiers, no second alert
        h.advance(120)
        h.ensureData()
        let bolusRaws = h.delegate.allEvents.filter { $0.dose?.type == .bolus }.map(\.raw)
        XCTAssertEqual(Set(bolusRaws).count, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            h.delegate.issuedAlerts
                .filter { $0.identifier.alertIdentifier == InsightAlertCatalog.unreadableHistoryAlertIdentifier }.count,
            1
        )

        // the bridge delivers it readably: sequence moves on, alert is retracted
        h.client.historyResult = .success(HistoryResult(
            events: [
                good,
                h.historyEvent(102, "bolusDelivered", after: -8, #"{"bolusId":2,"programmed":2.5,"delivered":2.5}"#),
                afterwards
            ],
            lastSequence: 103, more: false
        ))
        h.advance(120)
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 103)
        XCTAssertFalse(h.state.unreadableHistoryAlertIssued)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            h.delegate.retractedAlerts
                .contains { $0.alertIdentifier == InsightAlertCatalog.unreadableHistoryAlertIdentifier }
        )
    }

    func testUnreadableEventWithoutSequenceFreezesTheSequence() {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 105)
        h.client.historyResult = .success(HistoryResult(
            events: [h.historyEvent(101, "tubeFilled", after: -10, #"{"units":5}"#)], lastSequence: 105, more: false,
            unreadable: [UnreadableHistoryEvent(seq: nil, typeName: nil, time: nil, programmed: nil)]
        ))
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 100)
        XCTAssertTrue(h.state.unreadableHistoryAlertIssued)
    }

    func testDecodingKeepsWhatCanBeReadOfABrokenEvent() throws {
        let page = try BridgeJSON.decode(HistoryResult.self, from: json("""
        {"events":[{"seq":7,"time":"not a date","type":"bolusDelivered","data":{"programmed":3.0,"delivered":3.0}},
                   {"seq":8,"time":"2026-11-18T10:00:00Z","type":"other","data":{}}],"lastSequence":8}
        """))
        XCTAssertEqual(page.events.map(\.seq), [8])
        XCTAssertEqual(page.unreadable.first?.seq, 7)
        XCTAssertEqual(page.unreadable.first?.programmed, 3.0)
        XCTAssertEqual(page.unreadable.first?.isBolus, true)
    }

    func testImplausibleBolusFromTheMapperBlocksTheSequenceToo() async throws {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 101)
        h.client.history = [h.historyEvent(101, "bolusDelivered", after: -10, #"{"programmed":2.0,"delivered":"garbage"}"#)]
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 100)
        let dose = h.delegate.allEvents.compactMap(\.dose).first { $0.type == .bolus }
        XCTAssertEqual(dose?.deliveredUnits, 2.0)
        XCTAssertTrue(h.state.unreadableHistoryAlertIssued)
    }
}

// MARK: - low findings

final class LowFindingsTests: XCTestCase {
    func testSingleSessionRejectIsOnlyASuspicionAndClearsAfterASuccessfulSession() {
        let t = SessionTestCase()
        t.setUp()
        t.bridge.rejectSession = true
        t.connect()
        XCTAssertTrue(t.session.repairSuspected)
        XCTAssertNotEqual(t.session.state, .needsRepair("unknownClient"))
        t.bridge.rejectSession = false
        t.advance(31)
        t.link.state = .connecting
        t.flush()
        t.link.state = .connected
        t.flush()
        XCTAssertEqual(t.session.state, .ready)
        XCTAssertFalse(t.session.repairSuspected)
        t.tearDown()
    }

    func testPlaintextRejectOutsideAHandshakeIsIgnored() {
        let t = SessionTestCase()
        t.setUp()
        t.connect()
        t.link.deliver(try! HandshakeMessage.encode(["t": "sessionReject", "reason": "unknownClient"]))
        t.flush()
        XCTAssertEqual(t.session.state, .ready, "a plaintext reject cannot tear down an authenticated session")
        XCTAssertFalse(t.session.repairSuspected)
        t.tearDown()
    }

    func testSessionStateCanBeReadFromManyThreads() {
        let t = SessionTestCase()
        t.setUp()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0 ..< 40 {
                t.link.state = .connecting
                t.link.state = .connected
                t.queue.sync {}
            }
            group.leave()
        }
        DispatchQueue.concurrentPerform(iterations: 4000) { _ in
            _ = t.session.state
            _ = t.session.hello
            _ = t.session.repairSuspected
        }
        group.wait()
        t.tearDown()
    }

    func testBolusIsSentOnTheStepGrid() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.2000000000000002))
        XCTAssertEqual(h.client.deliverBolusCalls[0].amount, 1.2)
        XCTAssertEqual("\(h.client.deliverBolusCalls[0].amount)", "1.2")
        XCTAssertEqual(InsightPumpManager.normalizedBolus(0.35, step: 0.05), 0.35)
        XCTAssertEqual(InsightPumpManager.normalizedBolus(2.45, step: 0.05), 2.45)
        XCTAssertEqual(InsightPumpManager.normalizedBolus(3.0000000001, step: 0.05), 3.0)
        for i in 1 ... 500 {
            let v = Double(i) * 0.05
            XCTAssertEqual(InsightPumpManager.normalizedBolus(v, step: 0.05), (v * 100).rounded() / 100, accuracy: 1E-12)
        }
    }

    func testDosingIsRefusedWhenThePumpIsNotConnectedToTheBridge() {
        for link in [PumpLinkState.disconnected, .connecting, .unknown] {
            let h = ManagerHarness { $0.lastPumpReadDate = Date() }
            // read long before this request: a cached "pump not connected" is believed
            h.client.status = BridgeStatus(
                timestamp: h.now.addingTimeInterval(-300),
                pumpLink: link,
                serial: "SN1",
                basal: .init(activeProfile: 1, rate: 1.0)
            )
            guard case .connection? = h.bolus(1.0) else { XCTFail("\(link)")
                continue }
            XCTAssertTrue(h.client.deliverBolusCalls.isEmpty, "\(link)")
            XCTAssertFalse(h.state.isDeliveryUncertain, "a refusal before sending is certain")
            guard case .connection? = h.tbr(1.5) else { XCTFail()
                continue }
            XCTAssertTrue(h.client.setTbrCalls.isEmpty)
        }
    }

    func testOnDemandBridgeStatusReadForTheRequestCountsAsConnected() {
        // On-demand bridge: it connects to the pump for our getStatus and reports the link as down afterwards.
        for link in [PumpLinkState.disconnected, .connecting, .unknown] {
            let h = ManagerHarness { $0.lastPumpReadDate = Date().addingTimeInterval(-10) }
            h.client.status = BridgeStatus(
                timestamp: h.now.addingTimeInterval(1), pumpLink: link, serial: "SN1", basal: .init(activeProfile: 1, rate: 1.0)
            )
            XCTAssertNil(h.bolus(1.0), "\(link)")
            XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
            // every command makes the bridge read the pump again: a newer read time each time
            h.client.status = BridgeStatus(
                timestamp: h.now.addingTimeInterval(2), pumpLink: link, serial: "SN1", basal: .init(activeProfile: 1, rate: 1.0)
            )
            XCTAssertNil(h.tbr(1.5), "\(link)")
        }
    }

    func testOnDemandCachedStatusDoesNotShortcutPreflight() {
        let h = ManagerHarness { $0.lastPumpReadDate = Date().addingTimeInterval(-10) }
        h.client.status = BridgeStatus(
            timestamp: h.now.addingTimeInterval(1), pumpLink: .disconnected, serial: "SN1",
            basal: .init(activeProfile: 1, rate: 1.0)
        )
        h.ensureData()
        let before = h.client.statusCalls
        h.client.status = BridgeStatus(
            timestamp: h.now.addingTimeInterval(2), pumpLink: .disconnected, serial: "SN1",
            basal: .init(activeProfile: 1, rate: 1.0)
        )
        XCTAssertNil(h.tbr(1.5))
        XCTAssertGreaterThan(h.client.statusCalls, before, "a status that says 'not connected' is never trusted from the cache")
    }

    func testOnDemandStatusThatIsNotNewerThanTheKnownReadIsRefused() {
        // The bridge answers with the cached read it already gave us (no pump contact for this request).
        let h = ManagerHarness { $0.lastPumpReadDate = Date().addingTimeInterval(-10) }
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(1), pumpLink: .disconnected, serial: "SN1")
        h.ensureData()
        guard case .connection? = h.bolus(1.0) else { return XCTFail("same read time: not read for this request") }
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)
    }

    func testDosingIsRefusedWithFreshStatusShortcutAndDisconnectedPump() {
        let h = ManagerHarness()
        h.client.status = BridgeStatus(timestamp: h.now.addingTimeInterval(-120), pumpLink: .disconnected, serial: "SN1")
        h.ensureData() // loads the (disconnected) status
        guard case .connection? = h.bolus(1.0) else { return XCTFail() }
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)
        // the pump comes back
        h.advance(70)
        h.client.status = h.status(after: 5)
        XCTAssertNil(h.bolus(1.0))
    }

    func testDosingIsRefusedWhenThePumpDataIsOlderThanFifteenMinutes() {
        let h = ManagerHarness()
        h.client.status = h.status(after: -16 * 60)
        guard case .connection? = h.bolus(1.0) else { return XCTFail() }
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)
        guard case .connection? = h.tbr(1.5) else { return XCTFail() }
        h.advance(70)
        h.client.status = h.status(after: 5)
        XCTAssertNil(h.bolus(1.0))
    }

    func testStateRoundTripIncludesTheNewRecords() throws {
        var s = InsightPumpManagerState(bridgeId: "b", bridgeName: "n", peripheralIdentifier: nil)
        s.tempBasals = [ActiveTempBasal(
            percent: 120,
            durationMinutes: 30,
            start: Date(timeIntervalSince1970: 3000),
            scheduledRate: 0.9,
            effectiveRate: 1.08,
            decisionId: UUID(),
            automatic: true,
            endedAt: nil,
            schedule: ManagerHarness.flatSchedule(0.9),
            utcOffsetSeconds: 3600
        )]
        s.bolus = UnfinalizedBolus(
            requestId: "r",
            units: 1.5,
            startDate: Date(timeIntervalSince1970: 1),
            bolusId: 4,
            decisionId: nil,
            automatic: false,
            insulinType: nil,
            deliveredUnits: 0.5,
            phase: .inProgress,
            endDate: nil,
            programmedOnPump: false,
            acceptedAt: Date(timeIntervalSince1970: 2),
            missCount: 1
        )
        s.finalizedLocal = [FinalizedLocalDose(
            kind: .tempBasal,
            key: "k",
            start: Date(timeIntervalSince1970: 5),
            end: Date(timeIntervalSince1970: 9),
            bolusId: nil,
            units: nil,
            percent: 120,
            finalizedAt: Date(timeIntervalSince1970: 10)
        )]
        s.finalizedBolusIds = [1, 2, 3]
        s
            .scheduleRevisions =
            [ScheduleRevision(effectiveFrom: Date(timeIntervalSince1970: 7), schedule: ManagerHarness.flatSchedule(1.1))]
        s.unreadableHistoryAlertIssued = true
        s.modeChangedAt = Date(timeIntervalSince1970: 11)
        let restored = try XCTUnwrap(InsightPumpManagerState(rawValue: s.rawValue))
        XCTAssertEqual(restored, s)
    }
}
