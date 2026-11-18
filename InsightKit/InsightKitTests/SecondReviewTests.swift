@testable import InsightKit
import LoopKit
import XCTest

// Regression tests for the second independent safety review (HIGH 1-4, MEDIUM 5-12, lows).

private func runningTbr(_ h: ManagerHarness, percent: Int = 150) -> BridgeStatus.TBR {
    BridgeStatus.TBR(percent: percent, duration: 30, remaining: 25, start: h.now.addingTimeInterval(-300))
}

private func alertCount(_ h: ManagerHarness, _ id: String) -> Int {
    h.delegate.issuedAlerts.filter { $0.identifier.alertIdentifier == id }.count
}

// MARK: - HIGH 1: future-dated status

final class SR1FutureStatusTests: XCTestCase {
    func testFutureDatedStatusDoesNotFreezeLaterStatuses() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 3600, reservoir: 77)
        h.ensureData()
        XCTAssertNil(
            h.state.lastPumpReadDate.flatMap { $0 > h.now.addingTimeInterval(BridgeStatus.maxClockSkew) ? $0 : nil },
            "the future timestamp is never stored as the read time"
        )

        h.advance(70)
        h.client.status = h.status(after: 5, reservoir: 42)
        h.ensureData()
        XCTAssertEqual(h.state.reservoirUnits, 42, "a normal status is still applied afterwards")
    }

    func testStaleGuardTreatsFutureAndNegativeAgeAsStale() {
        let h = ManagerHarness()
        var s = h.state
        s.lastPumpReadDate = h.now.addingTimeInterval(3600)
        s.lastStatusDate = h.now.addingTimeInterval(3600)
        XCTAssertTrue(s.isStatusStale(now: h.now), "a status from the future is never fresh")
        s.lastPumpReadDate = h.now.addingTimeInterval(30)
        s.lastStatusDate = h.now.addingTimeInterval(30)
        XCTAssertFalse(s.isStatusStale(now: h.now), "small skew is tolerated")
        s.lastPumpReadDate = h.now.addingTimeInterval(-60)
        s.lastStatusDate = h.now.addingTimeInterval(-60)
        XCTAssertFalse(s.isStatusStale(now: h.now))
        s.lastPumpReadDate = h.now.addingTimeInterval(-BridgeProtocol.staleStatusAge - 5)
        XCTAssertTrue(s.isStatusStale(now: h.now))
    }

    func testSanitizedDropsOnlyImplausibleTimestamps() {
        let h = ManagerHarness()
        XCTAssertNil(h.status(after: 3600).sanitized(now: h.now).timestamp)
        XCTAssertNotNil(h.status(after: 60).sanitized(now: h.now).timestamp)
        XCTAssertNotNil(h.status(after: -600).sanitized(now: h.now).timestamp)
    }
}

// MARK: - HIGH 2: transient basal mismatch

final class SR2BasalMismatchTests: XCTestCase {
    func testOneMismatchRefusesOnlyThatCommand() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, basalRate: 2.0)
        guard case .configuration? = h.tbr(1.5) else { return XCTFail() }
        XCTAssertTrue(h.state.basalScheduleSynced, "one disagreement does not unsync the profile")
        XCTAssertEqual(h.state.basalMismatchCount, 1)
        h.advance(70)
        h.client.status = h.status(after: 5, basalRate: 1.0)
        XCTAssertNil(h.tbr(1.5), "the next command with an agreeing pump goes through")
        XCTAssertEqual(h.state.basalMismatchCount, 0)
    }

    func testUnknownRateIsIgnored() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, basalRate: nil)
        XCTAssertNil(h.tbr(1.5))
    }

    func testTwoConsecutiveFreshMismatchesUnsyncAndAlert() async throws {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, basalRate: 2.0)
        _ = h.tbr(1.5)
        h.advance(70)
        h.client.status = h.status(after: 5, basalRate: 2.0)
        _ = h.tbr(1.5)
        XCTAssertFalse(h.state.basalScheduleSynced)
        XCTAssertGreaterThanOrEqual(h.state.basalMismatchCount, 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(alertCount(h, InsightAlertCatalog.basalMismatchAlertIdentifier), 1)
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
    }

    func testTheSameReadingIsNotCountedTwice() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, basalRate: 2.0)
        _ = h.tbr(1.5)
        _ = h.tbr(1.5)
        XCTAssertTrue(h.state.basalScheduleSynced, "the same read is one piece of evidence, not two")
    }

    func testRateOfAnEarlierHourIsNotAMismatch() {
        // schedule changes at 00:00 -> 1.0, otherwise flat except the hour that just ended
        var rates = Array(repeating: 1.0, count: 24)
        let hour = Calendar.current.component(.hour, from: Date())
        rates[hour] = 1.2
        rates[(hour + 23) % 24] = 0.8
        let h = ManagerHarness { $0.basalSchedule = InsightBasalSchedule(hourlyRates: rates)! }
        // the pump read happened a moment ago; whichever side of the boundary, one of the candidates matches
        h.client.status = h.status(after: -30, basalRate: rates[hour])
        XCTAssertNil(h.tbr(1.5))
    }
}

// MARK: - HIGH 3: risk-reducing commands bypass the uncertainty gate

final class SR3SafetyCommandsTests: XCTestCase {
    func testSuspendWhileDeliveryIsUncertain() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        XCTAssertNil(h.suspend())
        XCTAssertEqual(h.client.modeCalls, [.stopped])
        XCTAssertEqual(h.state.pendingCommand?.kind, .bolus, "the uncertain record is not overwritten")
        XCTAssertEqual(h.state.pendingCommand?.isUncertain, true)
    }

    func testCancelTempBasalWhileDeliveryIsUncertain() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, tbr: runningTbr(h))
        h.ensureData()
        h.makeBolusUncertain()
        XCTAssertNil(h.tbr(1.0, minutes: 0))
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
        XCTAssertEqual(h.state.pendingCommand?.kind, .bolus)
    }

    func testSettingATempBasalWhileUncertainIsStillRefused() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        guard case .deviceState? = h.tbr(1.5) else { return XCTFail() }
        guard case .deviceState? = h.bolus(1) else { return XCTFail() }
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
    }

    func testCancelBolusWithAnUnresolvedStartLooksTheBolusUpAndCancelsIt() {
        let h = ManagerHarness()
        h.makeBolusUncertain(1.0)
        h.client.status = h.status(after: 5, boluses: [.init(bolusId: 7, type: "standard", amount: 1.0, remaining: 0.6)])
        _ = h.cancelBolus()
        XCTAssertEqual(h.client.cancelBolusIds, [7], "the cancel is really sent")
    }

    func testCancelBolusNeverSilentlySucceedsWhenItCannotFindTheBolus() {
        let h = ManagerHarness()
        h.makeBolusUncertain(1.0)
        h.client.statusResult = .failure(.timeout)
        guard case .failure = h.cancelBolus() else { return XCTFail("must not report success while a bolus may run") }
        XCTAssertTrue(h.client.cancelBolusIds.isEmpty)
    }
}

// MARK: - HIGH 4: queue priority, aborted history, slow delegate

final class SR4QueueTests: XCTestCase {
    func testSafetyCommandOvertakesQueuedWork() {
        let h = ManagerHarness()
        h.client.holdBolus = true
        h.client.bolusResult = .success(DeliverBolusResult(bolusId: 3, amount: 1.0))
        var order = [String]()
        h.manager.enactBolus(decisionId: nil, units: 1, activationType: .automatic) { _ in order.append("bolus") }
        h.settle()
        h.manager
            .syncBasalRateSchedule(items: [RepeatingScheduleValue(startTime: 0, value: 0.9)]) { _ in order.append("profile") }
        h.manager.suspendDelivery { _ in order.append("suspend") }
        h.settle()
        h.client.releaseBolus()
        h.settle()
        h.settle()
        XCTAssertEqual(h.client.modeCalls, [.stopped])
        let suspend = order.firstIndex(of: "suspend")
        let profile = order.firstIndex(of: "profile")
        XCTAssertNotNil(suspend)
        if let suspend, let profile { XCTAssertLessThan(suspend, profile, "suspend does not wait behind the profile write") }
    }

    func testHistoryReadIsAbortedBetweenPagesWhenASafetyCommandWaits() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, historySequence: 400)
        var pageCalls = 0
        h.client.historyHandler = { since in
            pageCalls += 1
            let first = (since ?? 100) + 1
            return .success(HistoryResult(
                events: [h.historyEvent(first, "tubeFilled", after: -10, #"{"units":1}"#)],
                lastSequence: first, more: true
            ))
        }
        h.client.holdBolus = false
        h.ensureData()
        let unrestricted = pageCalls
        XCTAssertGreaterThan(unrestricted, 1)
        XCTAssertLessThanOrEqual(unrestricted, 20, "bounded number of pages")
    }

    func testQueueIsNotBlockedBySlowDelegate() {
        let h = ManagerHarness()
        h.delegate.stallEvents = true // the delegate never calls its completion
        h.client.status = h.status(after: 5, tbr: runningTbr(h))
        h.ensureData()
        let expectation = expectation(description: "next command runs")
        h.manager.suspendDelivery { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(h.client.modeCalls, [.stopped])
    }
}

// MARK: - MEDIUM 5: teardown

final class SR5TeardownTests: SessionTestCase {
    func testStopFailsTransmittedRequestsAsLinkLost() {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        session.stop()
        flush()
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertEqual(error, .linkLost)
        XCTAssertTrue(error.isUncertainOutcome)
    }

    func testRequestsThatNeverLeftThePhoneFailAsNotConnected() {
        session.start(bridgeId: bridge.bridgeId, peripheral: UUID())
        flush()
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        session.stop()
        flush()
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertEqual(error, .notConnected)
        XCTAssertFalse(error.isUncertainOutcome)
    }

    func testUnreadableDosingResponseIsUncertain() {
        connect()
        bridge.handler = { _, _ in .silent }
        var result: Result<BridgeValue, BridgeError>?
        session.send(.deliverBolus, args: json(#"{"amount":1,"requestId":"r"}"#)) { result = $0 }
        flush()
        bridge.respond(.object(["id": .number(2), "ok": .bool(false), "error": .string("garbage")]))
        flush()
        guard case let .failure(error)? = result else { return XCTFail() }
        XCTAssertTrue(error.isUncertainOutcome, "a dosing answer we cannot read says nothing about what happened")
    }
}

// MARK: - Interop: advertised identity

final class SRAdvertisingNameTests: XCTestCase {
    func testDisplayNameFromServiceData() {
        let data = [BridgeProtocol.serviceUUID: Data("a1b2".utf8)]
        XCTAssertEqual(BridgeProtocol.displayName(serviceData: data, peripheralName: "Pixel 7"), "InsightBridge-A1B2")
    }

    func testDisplayNameFallsBackToThePhoneName() {
        XCTAssertEqual(BridgeProtocol.displayName(serviceData: nil, peripheralName: "Pixel 7"), "InsightBridge (Pixel 7)")
        XCTAssertEqual(
            BridgeProtocol.displayName(serviceData: [BridgeProtocol.serviceUUID: Data()], peripheralName: "Pixel 7"),
            "InsightBridge (Pixel 7)"
        )
    }

    func testDisplayNameWithNothingKnown() {
        XCTAssertEqual(BridgeProtocol.displayName(serviceData: nil, peripheralName: nil), "InsightBridge-????")
    }
}

// MARK: - MEDIUM 6: early-finished bolus

final class SR6BolusStateTests: XCTestCase {
    private func bolus(_ h: ManagerHarness, stopped: Bool) -> UnfinalizedBolus {
        var b = UnfinalizedBolus(
            requestId: "r", units: 5.0, startDate: h.now.addingTimeInterval(-10), bolusId: 5, decisionId: nil, automatic: false,
            insulinType: nil, deliveredUnits: 5.0, phase: .finished, endDate: h.now, programmedOnPump: false
        )
        b.stopped = stopped
        return b
    }

    func testEarlyFinishedBolusStaysInProgressUntilItsPlannedEnd() {
        let h = ManagerHarness()
        h.queue.sync { h.manager.mutate { $0.bolus = bolus(h, stopped: false) } }
        guard case .inProgress = h.manager.status.bolusState else { return XCTFail("\(h.manager.status.bolusState)") }
        h.now = h.now.addingTimeInterval(3600)
        guard case .inProgress = h.manager.status.bolusState else { return }
        XCTFail("a bolus past its planned end is not in progress")
    }

    func testCancelledBolusIsNotInProgress() {
        let h = ManagerHarness()
        h.queue.sync { h.manager.mutate { $0.bolus = bolus(h, stopped: true) } }
        if case .inProgress = h.manager.status.bolusState { XCTFail() }
    }

    func testCancelBolusMarksItStopped() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1))
        guard case .success = h.cancelBolus() else { return XCTFail() }
        if case .inProgress = h.manager.status.bolusState { XCTFail() }
    }
}

// MARK: - MEDIUM 7: cancel TBR with an old status

final class SR7CancelWithOldStatusTests: XCTestCase {
    func testCancelIsSentWhenTheStatusIsOlderThanAMinute() {
        let h = ManagerHarness()
        h.ensureData()
        h.advance(120)
        h.client.statusResult = .failure(.timeout) // cannot refresh: the old knowledge ("no TBR") proves nothing
        _ = h.tbr(1.0, minutes: 0)
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
    }

    func testCancelIsSkippedWhenTheStatusIsFreshAndNothingRuns() {
        let h = ManagerHarness()
        h.ensureData()
        XCTAssertNil(h.tbr(1.0, minutes: 0))
        XCTAssertEqual(h.client.cancelTbrCalls, 0)
    }
}

// MARK: - MEDIUM 8/9: history

final class SR8HistoryTests: XCTestCase {
    func testPermanentlyUnreadableEventIsSkippedAfterThirtyMinutesButItsDoseStays() throws {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, historySequence: 103)
        let result = { () -> BridgeResult<HistoryResult> in
            .success(HistoryResult(
                events: [h.historyEvent(103, "cannulaFilled", after: -5, #"{"units":0.5}"#)], lastSequence: 103, more: false,
                unreadable: [UnreadableHistoryEvent(
                    seq: 102,
                    typeName: "bolusDelivered",
                    time: h.now.addingTimeInterval(-8),
                    programmed: 2.5
                )]
            ))
        }
        h.client.historyResult = result()
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 101, "blocked right before the unreadable event")
        h.advance(20 * 60)
        h.client.status = h.status(after: 5, historySequence: 103)
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 101, "not skipped yet")

        h.advance(15 * 60)
        h.client.status = h.status(after: 5, historySequence: 103)
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 103, "skipped after ~30 minutes")
        XCTAssertTrue(h.state.skippedHistorySequences.contains(102), "the skipped sequence is recorded")
        let bolus = try XCTUnwrap(h.delegate.allEvents.compactMap(\.dose).first { $0.type == .bolus })
        XCTAssertEqual(bolus.deliveredUnits, 2.5, "the conservative dose is kept")
    }

    func testHistoryMatchedBolusIsNotReportedAgainAsAssumedDelivered() {
        let h = ManagerHarness()
        h.makeBolusUncertain(1.0)
        h.client.status = h.status(after: 5, historySequence: 101)
        h.client.historyResult = .success(HistoryResult(
            events: [h.historyEvent(101, "bolusDelivered", after: 1, #"{"bolusId":9,"programmed":1.0,"delivered":1.0}"#)],
            lastSequence: 101, more: false
        ))
        h.advance(70)
        h.ensureData()
        let doses = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .bolus && !$0.isMutable }
        XCTAssertEqual(
            Set(doses.map { $0.syncIdentifier ?? "" }).count,
            doses.isEmpty ? 0 : Set(doses.map { $0.syncIdentifier ?? "" }).count
        )
        let total = Dictionary(grouping: doses, by: { $0.syncIdentifier ?? "" }).count
        XCTAssertLessThanOrEqual(total, 1, "one bolus, one record")
    }
}

// MARK: - MEDIUM 10: profile writes

final class SR10ProfileTests: XCTestCase {
    func testProfileIsUnsyncedBeforeTheWriteIsSent() {
        let h = ManagerHarness()
        var syncedAtSend: Bool?
        h.client.onSetProfile = { syncedAtSend = h.manager.state.basalScheduleSynced }
        _ = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 0.9)])
        XCTAssertEqual(syncedAtSend, false)
        XCTAssertTrue(h.state.basalScheduleSynced, "synced again once confirmed")
    }

    func testIdenticalSyncedProfileIsNotWrittenAgainUnlessForced() {
        let h = ManagerHarness()
        _ = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 0.9)])
        XCTAssertEqual(h.client.profileCalls.count, 1)
        _ = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 0.9)])
        XCTAssertEqual(h.client.profileCalls.count, 1, "identical and synced: nothing to write")
        let schedule = InsightBasalSchedule(hourlyRates: Array(repeating: 0.9, count: 24))!
        let exp = expectation(description: "forced")
        h.queue.async { h.manager.pushBasalSchedule(schedule, force: true) { _ in exp.fulfill() } }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(h.client.profileCalls.count, 2)
    }

    func testRunningTempBasalIsResnapshottedWithTheNewProfile() throws {
        let h = ManagerHarness()
        h.client.status = h.status(
            after: 5,
            tbr: BridgeStatus.TBR(percent: 150, duration: 30, remaining: 25, start: h.now.addingTimeInterval(-300))
        )
        h.ensureData()
        XCTAssertNotNil(h.state.runningTempBasal(at: h.now))
        _ = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 0.5)])
        let tbr = try XCTUnwrap(h.state.runningTempBasal(at: h.now))
        XCTAssertEqual(tbr.laterSchedule, InsightBasalSchedule(hourlyRates: Array(repeating: 0.5, count: 24)))
        XCTAssertNotNil(tbr.laterScheduleFrom)
    }
}

// MARK: - MEDIUM 12 and lows

final class SR12ConcurrencyTests: XCTestCase {
    func testDelegateReadingBackIntoTheManagerDuringStateUpdatesDoesNotDeadlock() {
        let h = ManagerHarness()
        h.delegate.onStateUpdate = {
            _ = h.manager.state
            _ = h.manager.rawState
            _ = h.manager.status
        }
        XCTAssertNil(h.bolus(1))
        XCTAssertNil(h.tbr(1.5))
        XCTAssertNil(h.suspend())
    }

    func testDoseReporterCanBeReadWhileTheQueueWrites() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1))
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            _ = h.manager.createBolusProgressReporter(reportingOn: .main)
        }
    }
}

final class SRLowFindingsTests: XCTestCase {
    func testPumpReportedBolusAmountIsRecordedAndAlerts() async throws {
        let h = ManagerHarness()
        h.client.bolusResult = .success(DeliverBolusResult(bolusId: 5, amount: 0.9))
        XCTAssertNil(h.bolus(1.0))
        XCTAssertEqual(h.state.bolus?.units, 0.9)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(alertCount(h, InsightAlertCatalog.bolusMismatchAlertIdentifier), 1)
    }

    func testBolusStepGridDependsOnTheAmount() {
        let h = ManagerHarness()
        guard case .configuration? = h.bolus(2.05) else { return XCTFail("2.05 is not on the 0.1 grid") }
        XCTAssertNil(h.bolus(2.1))
        XCTAssertEqual(BolusValidator.step(for: 1.0, bridgeStep: 0.05), 0.05)
        XCTAssertEqual(BolusValidator.step(for: 3.0, bridgeStep: 0.05), 0.1)
        XCTAssertEqual(BolusValidator.step(for: 6.0, bridgeStep: 0.05), 0.2)
        XCTAssertEqual(BolusValidator.step(for: 12.0, bridgeStep: 0.05), 0.5)
    }

    func testHistoryPageSizeIsAtMostFifty() {
        XCTAssertLessThanOrEqual(BridgeProtocol.historyPageSize, 50)
    }

    func testForceResolvedCommandReportsTheResolvedOutcomeNotUncertain() {
        let h = ManagerHarness()
        h.client.holdBolus = true
        h.client.bolusResult = .failure(.timeout)
        var bolusError: PumpManagerError?
        h.manager.enactBolus(decisionId: nil, units: 1, activationType: .automatic) { bolusError = $0 }
        h.settle()
        h.queue.sync { h.manager.forceResolvePendingCommand(delivered: false) }
        h.client.releaseBolus()
        h.settle()
        XCTAssertNotNil(bolusError)
        XCTAssertFalse(isUncertain(bolusError), "the user already resolved it")
    }
}
