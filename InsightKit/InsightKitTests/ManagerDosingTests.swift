@testable import InsightKit
import LoopKit
import XCTest

final class ManagerBolusTests: XCTestCase {
    func testBolusSuccessTracksInProgressDose() throws {
        let h = ManagerHarness()
        let decision = UUID()
        XCTAssertNil(h.bolus(1.0, decision: decision))

        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
        XCTAssertEqual(h.client.deliverBolusCalls[0].amount, 1.0)
        XCTAssertNotNil(UUID(uuidString: h.client.deliverBolusCalls[0].requestId))
        let bolus = try XCTUnwrap(h.state.bolus)
        XCTAssertEqual(bolus.phase, .inProgress)
        XCTAssertEqual(bolus.bolusId, 7)
        XCTAssertNil(h.state.pendingCommand)
        guard case let .inProgress(dose) = h.manager.status.bolusState else { return XCTFail("\(h.manager.status.bolusState)") }
        XCTAssertEqual(dose.programmedUnits, 1.0)
        XCTAssertEqual(dose.decisionId, decision)
        XCTAssertNotNil(h.manager.createBolusProgressReporter(reportingOn: .main))

        let mutable = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .bolus && $0.isMutable }
        XCTAssertEqual(mutable.count, 1)
        XCTAssertTrue(h.delegate.replaceFlags.allSatisfy { $0 }, "complete set of mutable doses is always sent")
    }

    func testInvalidBolusesAreRejectedWithoutTouchingThePump() {
        let h = ManagerHarness()
        for units in [0.0, -1.0, 1.23, 10.05, .nan] {
            guard case .configuration? = h.bolus(units) else { XCTFail("\(units) should be a configuration error")
                continue }
        }
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertEqual(h.manager.status.bolusState, .noBolus)
    }

    func testBolusAboveReservoirAndLocalLimitIsRejected() {
        let h = ManagerHarness { $0.reservoirUnits = 2
            $0.maxBolus = 1.5 }
        guard case .configuration? = h.bolus(1.6) else { return XCTFail() }
        XCTAssertNil(h.bolus(1.5))
    }

    func testBolusWhileSuspendedOrBusyIsRejected() {
        let h = ManagerHarness { $0.operatingMode = .stopped }
        guard case .deviceState? = h.bolus(1) else { return XCTFail() }
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)

        let h2 = ManagerHarness()
        XCTAssertNil(h2.bolus(1))
        guard case .deviceState? = h2.bolus(1) else { return XCTFail("second bolus while one runs") }
        XCTAssertEqual(h2.client.deliverBolusCalls.count, 1)
    }

    func testCertainBridgeFailureLeavesNoTrace() {
        let h = ManagerHarness()
        h.client.bolusResult = .failure(.remote(BridgeRemoteError(code: .pumpSuspended, message: "", uncertain: false)))
        guard case .deviceState? = h.bolus(1) else { return XCTFail() }
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertNil(h.state.bolus)
        XCTAssertFalse(h.manager.status.deliveryIsUncertain)
        h.client.bolusResult = .success(DeliverBolusResult(bolusId: 1, amount: 1))
        XCTAssertNil(h.bolus(1), "a certain failure does not block the next bolus")
    }

    func testNotConnectedIsCertainFailure() {
        let h = ManagerHarness()
        h.client.bolusResult = .failure(.notConnected)
        guard case .connection? = h.bolus(1) else { return XCTFail() }
        XCTAssertFalse(h.state.isDeliveryUncertain)
    }

    func testCancelBolusReturnsDeliveredAmount() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(2.0))
        h.client.cancelBolusResult = .success(CancelBolusResult(delivered: 0.75))
        guard case let .success(dose?) = h.cancelBolus() else { return XCTFail() }
        XCTAssertEqual(dose.deliveredUnits, 0.75)
        XCTAssertEqual(dose.programmedUnits, 2.0)
        XCTAssertEqual(h.state.bolus?.phase, .finished)
        XCTAssertEqual(h.manager.status.bolusState, .noBolus)
    }

    func testCancelWithoutBolusIsANoOp() {
        let h = ManagerHarness()
        guard case let .success(dose) = h.cancelBolus() else { return XCTFail() }
        XCTAssertNil(dose)
    }

    func testBolusProgressEventsDriveTheReporter() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(2.0))
        let reporter = try XCTUnwrap(h.manager.createBolusProgressReporter(reportingOn: .main))
        h.manager.bridgeClient(h.client, didReceive: .bolusProgress(BolusProgress(bolusId: 7, delivered: 0.5, remaining: 1.5)))
        h.settle()
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.5, accuracy: 1E-9)
        XCTAssertEqual(reporter.progress.percentComplete, 0.25, accuracy: 1E-9)
        // other bolus ids are ignored
        h.manager.bridgeClient(h.client, didReceive: .bolusProgress(BolusProgress(bolusId: 99, delivered: 2.0, remaining: 0)))
        h.settle()
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.5, accuracy: 1E-9)
    }

    func testBolusFinishedInStatusIsFinalizedFromHistory() throws {
        let h = ManagerHarness()
        let decision = UUID()
        XCTAssertNil(h.bolus(1.0, decision: decision))
        h.advance(60)
        let start = h.client.deliverBolusCalls.isEmpty ? 0 : -50.0
        h.client.status = h.status(after: 1, historySequence: 101)
        h.client.history = [h.historyEvent(
            101,
            "bolusDelivered",
            after: start + 40,
            #"{"bolusId":7,"bolusType":"standard","programmed":1.0,"delivered":1.0}"#
        )]
        h.ensureData()

        XCTAssertNil(h.state.bolus, "matched and finalized")
        XCTAssertEqual(h.state.lastHistorySequence, 101)
        let finals = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .bolus && !$0.isMutable }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.decisionId, decision)
        XCTAssertEqual(finals.first?.deliveredUnits, 1.0)
        XCTAssertEqual(h.manager.status.bolusState, .noBolus)
    }

    func testBolusNeverSeenInHistoryIsKeptAsDeliveredAfterGrace() {
        let h = ManagerHarness()
        XCTAssertNil(h.bolus(1.0))
        h.client.status = h.status(after: 100)
        h.advance(100)
        h.ensureData() // status shows no bolus -> finished
        XCTAssertEqual(h.state.bolus?.phase, .finished)
        h.advance(20 * 60)
        h.client.status = h.status(after: 1)
        h.ensureData()
        XCTAssertNil(h.state.bolus)
        let finals = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .bolus && !$0.isMutable }
        XCTAssertEqual(finals.count, 1, "IOB is never lost when the history is silent")
        XCTAssertEqual(finals.first?.deliveredUnits, 1.0)
    }
}

final class ManagerUncertainDeliveryTests: XCTestCase {
    func testTimeoutOnBolusIsUncertainAndNeverRetried() {
        let h = ManagerHarness()
        h.client.bolusResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.bolus(1.0)))

        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
        XCTAssertEqual(h.state.pendingCommand?.kind, .bolus)
        XCTAssertEqual(h.state.pendingCommand?.isUncertain, true)
        XCTAssertTrue(h.manager.status.deliveryIsUncertain)

        // Possibly-delivered insulin is counted (mutable) so IOB errs on the safe side.
        let doses = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .bolus }
        XCTAssertEqual(doses.count, 1)
        XCTAssertTrue(doses[0].isMutable)
        XCTAssertEqual(doses[0].programmedUnits, 1.0)

        // Time passes, connections come and go, retries fire: still exactly one deliverBolus.
        for _ in 0 ..< 5 { h.advance(61) }
        h.ensureData()
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1, "safety invariant: no automatic retry")
    }

    func testRemoteUncertainFlagAndLinkLostAreUncertainToo() {
        for error in [BridgeError.linkLost, .remote(BridgeRemoteError(code: .pumpUnreachable, message: "", uncertain: true))] {
            let h = ManagerHarness()
            h.client.bolusResult = .failure(error)
            XCTAssertTrue(isUncertain(h.bolus(1.0)), "\(error)")
        }
    }

    func testNoDosingWhileUncertain() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        guard case .deviceState? = h.bolus(0.5) else { return XCTFail() }
        guard case .deviceState? = h.tbr(1.5) else { return XCTFail() }
        // risk reducing commands are NOT blocked (see SecondReviewTests); everything that adds insulin is
        XCTAssertNotNil(h.resume() ?? (h.state.isSuspended ? nil : NSError(domain: "x", code: 1)))
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
    }

    func testResolvedAsDeliveredFromHistory() throws {
        let h = ManagerHarness()
        let decision = UUID()
        h.client.bolusResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.bolus(1.0, decision: decision)))

        h.client.status = h.status(after: 60, historySequence: 101)
        h.client.history = [h.historyEvent(
            101,
            "bolusDelivered",
            after: 5,
            #"{"bolusId":3,"bolusType":"standard","programmed":1.0,"delivered":1.0}"#
        )]
        h.advance(6) // resolution timer

        XCTAssertNil(h.state.pendingCommand, "resolved")
        XCTAssertFalse(h.manager.status.deliveryIsUncertain)
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
        let finals = h.delegate.eventBatches.flatMap { $0 }.compactMap(\.dose).filter { $0.type == .bolus && !$0.isMutable }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals[0].decisionId, decision, "the history dose is attributed to our command")
        XCTAssertEqual(h.delegate.eventBatches.last?.compactMap(\.dose).filter(\.isMutable).count, 0)
    }

    func testResolvedAsNotDeliveredDropsTheAssumedDose() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.status = h.status(after: 100)
        h.advance(6)
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertFalse(h.manager.status.deliveryIsUncertain)
        XCTAssertEqual(h.delegate.eventBatches.last?.compactMap(\.dose).count, 0, "the assumed bolus is replaced by nothing")
        XCTAssertTrue(h.delegate.replaceFlags.last == true)
        XCTAssertEqual(h.client.deliverBolusCalls.count, 1)
        h.client.bolusResult = .success(DeliverBolusResult(bolusId: 9, amount: 1.0))
        XCTAssertNil(h.bolus(1.0), "dosing is possible again after resolution")
    }

    func testStaleStatusCannotProveThatNothingWasDelivered() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.status = h.status(after: -120) // bridge last read the pump before the command was sent
        h.advance(6)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        h.advance(61)
        XCTAssertTrue(h.state.isDeliveryUncertain, "keeps trying, keeps blocking")
    }

    func testUnreachableBridgeKeepsUncertaintyAndRetries() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.statusResult = .failure(.notConnected)
        h.advance(6)
        h.advance(61)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        h.client.statusResult = nil
        h.client.status = h.status(after: 100)
        h.advance(61)
        XCTAssertFalse(h.state.isDeliveryUncertain)
    }

    func testBolusStillRunningOnPumpIsAdopted() throws {
        let h = ManagerHarness()
        let decision = UUID()
        h.client.bolusResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.bolus(1.0, decision: decision)))
        h.client.status = h.status(after: 20, boluses: [.init(bolusId: 5, type: "standard", amount: 1.0, remaining: 0.6)])
        h.advance(6)
        XCTAssertNil(h.state.pendingCommand)
        let bolus = try XCTUnwrap(h.state.bolus)
        XCTAssertEqual(bolus.bolusId, 5)
        XCTAssertEqual(bolus.decisionId, decision)
        XCTAssertEqual(bolus.deliveredUnits, 0.4, accuracy: 1E-9)
        guard case .inProgress = h.manager.status.bolusState else { return XCTFail() }
    }

    func testUserResolution() {
        let h = ManagerHarness()
        h.makeBolusUncertain(1.5)
        let done = expectation(description: "forced")
        h.manager.forceResolvePendingCommand(delivered: true) { done.fulfill() }
        wait(for: [done], timeout: 5)
        h.settle()
        XCTAssertNil(h.state.pendingCommand)
        XCTAssertEqual(h.state.bolus?.units, 1.5, "user said it was delivered -> counted")
        XCTAssertEqual(h.state.bolus?.phase, .finished)

        let h2 = ManagerHarness()
        h2.makeBolusUncertain(1.5)
        let done2 = expectation(description: "forced2")
        h2.manager.forceResolvePendingCommand(delivered: false) { done2.fulfill() }
        wait(for: [done2], timeout: 5)
        h2.settle()
        XCTAssertNil(h2.state.pendingCommand)
        XCTAssertNil(h2.state.bolus)
    }

    func testPendingCommandFromBeforeARestartIsUncertain() throws {
        let h = ManagerHarness()
        var state = h.state
        state.pendingCommand = PendingCommand(
            kind: .bolus, requestId: "r", sentDate: Date(), baselineSequence: 100, units: 1, percent: nil, durationMinutes: nil,
            scheduledRate: nil, decisionId: nil, automatic: true, insulinType: nil, isUncertain: false
        )
        let restored = try XCTUnwrap(InsightPumpManagerState(rawValue: state.rawValue))
        XCTAssertEqual(restored.pendingCommand?.isUncertain, true)
        XCTAssertTrue(restored.isDeliveryUncertain)
    }

    func testHistoryIsNotConsumedPastTheUncertainCommand() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        h.client.status = h.status(after: 5, historySequence: 105)
        h.client.statusResult = nil
        h.client.history = (101 ... 105).map { h.historyEvent($0, "other", after: 1, #"{"raw":"x"}"#) }
        h.client.historyResult = nil
        h.ensureData()
        XCTAssertLessThanOrEqual(
            h.state.lastHistorySequence ?? 0,
            100,
            "events after the command stay unread until it is resolved"
        )
    }

    func testResolverPureCases() {
        let sent = Date()
        func cmd(_ kind: PendingCommand.Kind, units: Double? = nil, percent: Int? = nil) -> PendingCommand {
            PendingCommand(
                kind: kind,
                requestId: "r",
                sentDate: sent,
                baselineSequence: 10,
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
        // `fresh`: read well after the command (settled); the pump is connected
        func status(fresh: Bool, mode: PumpOperatingMode = .started, tbr: BridgeStatus.TBR? = nil) -> BridgeStatus {
            BridgeStatus(timestamp: sent.addingTimeInterval(fresh ? 90 : -30), operatingMode: mode, tbr: tbr)
        }
        let tbr150 = BridgeStatus.TBR(percent: 150, duration: 30, remaining: 20, start: sent)
        XCTAssertEqual(
            UncertaintyResolver
                .decide(
                    command: cmd(.setTBR, percent: 150),
                    status: status(fresh: true, tbr: tbr150),
                    history: [],
                    historyComplete: true
                ),
            .delivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.setTBR, percent: 150), status: status(fresh: true), history: [], historyComplete: true),
            .notDelivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.setTBR, percent: 150), status: status(fresh: true), history: [], historyComplete: false),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.setTBR, percent: 150), status: status(fresh: false), history: [], historyComplete: true),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver.decide(command: cmd(.cancelTBR), status: status(fresh: true), history: [], historyComplete: true),
            .delivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.cancelTBR), status: status(fresh: true, tbr: tbr150), history: [], historyComplete: true),
            .notDelivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.suspend), status: status(fresh: true, mode: .stopped), history: [], historyComplete: true),
            .delivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.suspend), status: status(fresh: true, mode: .started), history: [], historyComplete: true),
            .notDelivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.resume), status: status(fresh: true, mode: .started), history: [], historyComplete: true),
            .delivered
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.resume), status: status(fresh: true, mode: .unknown), history: [], historyComplete: true),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.bolus, units: 1), status: status(fresh: false), history: [], historyComplete: true),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.bolus, units: 1), status: status(fresh: true), history: [], historyComplete: false),
            .undecided
        )
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.bolus, units: 1), status: status(fresh: true), history: [], historyComplete: true),
            .notDelivered
        )
        // an event with a different amount, or older than the command, is not evidence
        let other = HistoryEvent(seq: 11, time: sent, type: "bolusDelivered", data: json(#"{"programmed":2.0,"delivered":2.0}"#))
        let old = HistoryEvent(seq: 9, time: sent, type: "bolusDelivered", data: json(#"{"programmed":1.0,"delivered":1.0}"#))
        XCTAssertEqual(
            UncertaintyResolver
                .decide(
                    command: cmd(.bolus, units: 1),
                    status: status(fresh: true),
                    history: [other, old],
                    historyComplete: true
                ),
            .notDelivered
        )
        let match = HistoryEvent(seq: 11, time: sent, type: "bolusDelivered", data: json(#"{"programmed":1.0,"delivered":1.0}"#))
        XCTAssertEqual(
            UncertaintyResolver
                .decide(command: cmd(.bolus, units: 1), status: status(fresh: false), history: [match], historyComplete: false),
            .delivered
        )
    }
}

final class ManagerTempBasalTests: XCTestCase {
    func testTempBasalIsConvertedToPercentAndReported() throws {
        let h = ManagerHarness()
        let decision = UUID()
        XCTAssertNil(h.tbr(1.5, minutes: 30, decision: decision))
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
        XCTAssertEqual(h.client.setTbrCalls[0].percent, 150)
        XCTAssertEqual(h.client.setTbrCalls[0].duration, 30)

        guard case let .tempBasal(dose)? = h.manager.status.basalDeliveryState
        else { return XCTFail("\(String(describing: h.manager.status.basalDeliveryState))") }
        XCTAssertEqual(dose.unitsPerHour, 1.5, accuracy: 1E-9)
        XCTAssertEqual(dose.decisionId, decision)
        XCTAssertEqual(dose.scheduledBasalRate?.doubleValue(for: DoseEntry.unitsPerHour), 1.0)
        let events = h.delegate.eventBatches.last?.compactMap(\.dose).filter { $0.type == .tempBasal } ?? []
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isMutable)
        XCTAssertEqual(events[0].endDate.timeIntervalSince(events[0].startDate), 30 * 60, accuracy: 1)
    }

    func testRateIsRoundedDownAndTheActualRateIsReported() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.19, minutes: 44))
        XCTAssertEqual(h.client.setTbrCalls[0].percent, 110)
        XCTAssertEqual(h.client.setTbrCalls[0].duration, 30)
        let tbr = try XCTUnwrap(h.state.tempBasals.last)
        XCTAssertEqual(tbr.effectiveRate, 1.1, accuracy: 1E-9)
        guard case let .tempBasal(dose)? = h.manager.status.basalDeliveryState else { return XCTFail() }
        XCTAssertEqual(dose.unitsPerHour, 1.1, accuracy: 1E-9)
    }

    func testZeroAndCapped() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(0))
        XCTAssertEqual(h.client.setTbrCalls.last?.percent, 0)
        XCTAssertNil(h.tbr(4.0))
        XCTAssertEqual(h.client.setTbrCalls.last?.percent, 250)
        XCTAssertEqual(h.state.tempBasals.last?.effectiveRate ?? 0, 2.5, accuracy: 1E-9)
    }

    func testRateAboveMaximumBasalIsRejected() {
        let h = ManagerHarness { $0.basalSchedule = ManagerHarness.flatSchedule(3.0) }
        h.client.status = h.status(basalRate: 3.0)
        guard case .configuration? = h.tbr(5.5) else { return XCTFail() }
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
    }

    func testRequestEqualToScheduledCancelsRunningTbr() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        XCTAssertNil(h.tbr(1.0))
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
        XCTAssertNotNil(h.state.tempBasals.last?.endedAt)
        XCTAssertNil(h.state.runningTempBasal(at: h.now.addingTimeInterval(1)))
    }

    func testRequestEqualToScheduledWithoutTbrDoesNothing() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.0))
        XCTAssertEqual(h.client.cancelTbrCalls, 0)
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
    }

    func testZeroDurationCancels() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        XCTAssertNil(h.tbr(0, minutes: 0))
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
    }

    func testNewTbrEndsThePreviousOne() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        h.advance(300)
        XCTAssertNil(h.tbr(0.5))
        XCTAssertEqual(h.state.tempBasals.count, 2)
        XCTAssertNotNil(h.state.tempBasals[0].endedAt)
        XCTAssertNil(h.state.tempBasals[1].endedAt)
        let mutable = h.delegate.eventBatches.last?.compactMap(\.dose).filter { $0.type == .tempBasal } ?? []
        XCTAssertEqual(mutable.count, 2, "both stay reported until the history finalizes them")
    }

    func testTbrRefusedWhenScheduleNotConfirmedOrMismatching() {
        let h = ManagerHarness { $0.basalScheduleSynced = false }
        guard case .configuration? = h.tbr(1.5) else { return XCTFail() }
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)

        let h2 = ManagerHarness()
        h2.client.status = h2.status(basalRate: 1.3) // pump runs something else than we think
        guard case .configuration? = h2.tbr(1.5) else { return XCTFail() }
        XCTAssertTrue(h2.client.setTbrCalls.isEmpty)
        XCTAssertTrue(h2.state.basalScheduleSynced, "a single mismatch only refuses that command (see SecondReviewTests)")

        let h3 = ManagerHarness { $0.basalSchedule = nil }
        guard case .configuration? = h3.tbr(1.5) else { return XCTFail() }
    }

    func testTbrWhileSuspendedIsRejected() {
        let h = ManagerHarness { $0.operatingMode = .stopped }
        h.client.status = h.status(mode: .stopped)
        guard case .deviceState? = h.tbr(1.5) else { return XCTFail() }
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
    }

    func testTbrTimeoutIsUncertainNotRetriedAndResolvedFromStatus() throws {
        let h = ManagerHarness()
        let decision = UUID()
        h.client.tbrResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.tbr(1.5, decision: decision)))
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
        XCTAssertTrue(h.manager.status.deliveryIsUncertain)
        XCTAssertTrue(h.state.tempBasals.isEmpty)

        h.client.statusResult = .failure(.notConnected) // bridge unreachable for a while
        for _ in 0 ..< 3 { h.advance(61) }
        XCTAssertTrue(h.state.isDeliveryUncertain)
        XCTAssertEqual(h.client.setTbrCalls.count, 1, "no retry")

        h.client.statusResult = nil
        h.client.status = h.status(
            after: 100,
            tbr: .init(percent: 150, duration: 30, remaining: 25, start: h.now.addingTimeInterval(-5 * 60))
        )
        h.advance(61)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        let tbr = try XCTUnwrap(h.state.runningTempBasal(at: h.now))
        XCTAssertEqual(tbr.percent, 150)
        XCTAssertEqual(tbr.decisionId, decision)
        XCTAssertTrue(tbr.automatic)
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
    }

    func testTbrUncertainResolvedAsNotApplied() {
        let h = ManagerHarness()
        h.client.tbrResult = .failure(.linkLost)
        XCTAssertTrue(isUncertain(h.tbr(1.5)))
        h.client.status = h.status(after: 100)
        h.advance(6)
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        XCTAssertTrue(h.state.tempBasals.isEmpty)
    }

    func testCancelTbrTimeoutIsUncertain() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        h.client.cancelTbrResult = .failure(.timeout)
        XCTAssertTrue(isUncertain(h.tbr(1.0)))
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
        for _ in 0 ..< 3 { h.advance(61) }
        XCTAssertEqual(h.client.cancelTbrCalls, 1)
    }

    func testStatusWithoutTbrEndsOurRecord() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        h.advance(120)
        h.client.status = h.status(after: 1)
        h.ensureData()
        XCTAssertNotNil(h.state.tempBasals.last?.endedAt)
        XCTAssertEqual(
            h.manager.status.basalDeliveryState.map { if case .active = $0 { return true } else { return false } },
            true
        )
    }

    func testOldCachedStatusDoesNotEndAFreshTbr() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        h.client.status = h.status(after: -30) // read before the TBR was set
        h.advance(100)
        h.client.status = h.status(after: -200)
        h.ensureData()
        XCTAssertNil(h.state.tempBasals.last?.endedAt)
    }

    func testTbrHistoryFinalizationReplacesOurRecord() throws {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5, minutes: 30))
        let start = h.state.tempBasals[0].start
        h.client.status = h.status(after: 31 * 60, historySequence: 101)
        h.client
            .history =
            [HistoryEvent(
                seq: 101,
                time: start.addingTimeInterval(30 * 60),
                type: "tbrEnd",
                data: json(#"{"percent":150,"duration":30}"#)
            )]
        h.advance(31 * 60) // the TBR expiry timer triggers a sync
        XCTAssertTrue(h.state.tempBasals.isEmpty)
        let final = h.delegate.allEvents.compactMap(\.dose).filter { $0.type == .tempBasal && !$0.isMutable }
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.unitsPerHour ?? 0, 1.5, accuracy: 1E-9)
        XCTAssertEqual(h.delegate.eventBatches.last?.compactMap(\.dose).filter(\.isMutable).count, 0)
    }
}

final class ManagerSuspendResumeTests: XCTestCase {
    func testSuspendAndResume() {
        let h = ManagerHarness()
        h.client.status = h.status(after: 5, mode: .stopped)
        XCTAssertNil(h.suspend())
        XCTAssertEqual(h.client.modeCalls, [.stopped])
        XCTAssertTrue(h.state.isSuspended)
        if case .suspended? = h.manager.status.basalDeliveryState {} else { XCTFail() }

        h.client.status = h.status(after: 10, mode: .started)
        XCTAssertNil(h.resume())
        XCTAssertEqual(h.client.modeCalls, [.stopped, .started])
        XCTAssertFalse(h.state.isSuspended)
    }

    func testAlreadySuspendedIsIdempotent() {
        let h = ManagerHarness { $0.operatingMode = .paused }
        XCTAssertNil(h.suspend())
        XCTAssertTrue(h.client.modeCalls.isEmpty)
    }

    func testSuspendTimeoutIsUncertainAndResolvedByStatus() {
        let h = ManagerHarness()
        h.client.modeResult = .failure(.timeout)
        let error = h.suspend()
        XCTAssertTrue(error is PumpManagerError)
        XCTAssertTrue(h.state.isDeliveryUncertain)
        XCTAssertEqual(h.client.modeCalls.count, 1)
        h.client.status = h.status(after: 100, mode: .stopped)
        h.advance(6)
        XCTAssertFalse(h.state.isDeliveryUncertain)
        XCTAssertTrue(h.state.isSuspended)
        XCTAssertEqual(h.client.modeCalls.count, 1)
    }

    func testPumpSuspendedByUserIsVisibleFromStatus() {
        let h = ManagerHarness()
        h.client.status = h.status(mode: .stopped)
        h.ensureData()
        XCTAssertTrue(h.state.isSuspended)
        XCTAssertNotNil(h.state.suspendedSince)
    }
}

final class ManagerSettingsTests: XCTestCase {
    private func items(_ pairs: [(Double, Double)]) -> [RepeatingScheduleValue<Double>] {
        pairs.map { RepeatingScheduleValue(startTime: $0.0 * 3600, value: $0.1) }
    }

    func testBasalScheduleSync() throws {
        let h = ManagerHarness { $0.basalScheduleSynced = false
            $0.basalSchedule = nil }
        guard case let .success(schedule) = h.syncSchedule(items([(0, 0.8), (6, 1.2)])) else { return XCTFail() }
        XCTAssertEqual(schedule.items.count, 2)
        XCTAssertEqual(h.client.profileCalls.count, 1)
        XCTAssertEqual(
            h.client.profileCalls[0],
            [BasalSegment(duration: 360, rate: 0.8), BasalSegment(duration: 1080, rate: 1.2)]
        )
        XCTAssertTrue(h.state.basalScheduleSynced)
        XCTAssertEqual(h.state.basalSchedule?.hourlyRates[7], 1.2)
    }

    func testNonHourlyScheduleIsConvertedConservativelyInsteadOfRefused() {
        let h = ManagerHarness { $0.basalScheduleSynced = false }
        let half = [
            RepeatingScheduleValue(startTime: 0, value: 1.0),
            RepeatingScheduleValue(startTime: 1800, value: 1.2),
            RepeatingScheduleValue(startTime: 7200, value: 0.85),
            RepeatingScheduleValue(startTime: 9000, value: 0.9)
        ]
        guard case let .success(daily) = h.syncSchedule(half) else { return XCTFail("must not fail") }
        // hour 0: min(1.0, 1.2) = 1.0; hour 1: 1.2; hour 2: min(0.85, 0.85); hour 2.5 -> 0.9 starts inside hour 2
        let rates = h.state.basalSchedule!.hourlyRates
        XCTAssertEqual(rates[0], 1.0)
        XCTAssertEqual(rates[1], 1.2)
        XCTAssertEqual(rates[2], 0.85, "minimum of 0.85 and 0.9")
        XCTAssertEqual(rates[3], 0.9)
        XCTAssertEqual(h.client.profileCalls.count, 1)
        XCTAssertTrue(h.state.basalScheduleSynced)
        XCTAssertNotNil(h.state.simplifiedProfileSource, "recorded, and the user is told once")
        XCTAssertTrue(eventually {
            h.delegate.issuedAlerts
                .filter { $0.identifier.alertIdentifier == InsightAlertCatalog.profileSimplifiedAlertIdentifier }.count == 1 })
        XCTAssertEqual(daily.items.count, h.state.basalSchedule!.segments.count, "the schedule the pump runs is reported back")
        // TBR math uses the converted schedule
        h.advance(70) // cached status expires
        let pumpRateNow = h.state.basalSchedule!.rate(at: h.now, in: h.state.pumpTimeZone)
        h.client.status = h.status(basalRate: pumpRateNow)
        XCTAssertNil(h.tbr(pumpRateNow * 0.6))
        XCTAssertEqual(h.client.setTbrCalls.last?.percent, 60, "60% of what the PUMP runs (the converted schedule)")
        // the same profile again does not alert again
        _ = h.syncSchedule(half)
        _ = eventually(0.3) { false }
        XCTAssertEqual(
            h.delegate.issuedAlerts
                .filter { $0.identifier.alertIdentifier == InsightAlertCatalog.profileSimplifiedAlertIdentifier }.count,
            1
        )
    }

    func testHourlyScheduleIsNotReportedAsSimplified() {
        let h = ManagerHarness()
        let items = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 3600 * 6, value: 1.2)]
        guard case .success = h.syncSchedule(items) else { return XCTFail() }
        XCTAssertNil(h.state.simplifiedProfileSource)
        _ = eventually(0.3) { false }
        XCTAssertTrue(
            h.delegate.issuedAlerts
                .filter { $0.identifier.alertIdentifier == InsightAlertCatalog.profileSimplifiedAlertIdentifier }.isEmpty
        )
    }

    func testConversionRoundsDownToThePumpGridAndValidatesRange() throws {
        let c = try InsightBasalSchedule.simplified(items: [RepeatingScheduleValue(startTime: 0, value: 0.857)])
        XCTAssertEqual(c.schedule.hourlyRates[0], 0.85)
        XCTAssertTrue(c.wasSimplified)
        let high = try InsightBasalSchedule.simplified(items: [RepeatingScheduleValue(startTime: 0, value: 5.37)])
        XCTAssertEqual(high.schedule.hourlyRates[5], 5.3)
        XCTAssertThrowsError(try InsightBasalSchedule.simplified(items: [RepeatingScheduleValue(startTime: 0, value: 0.0)]))
        XCTAssertThrowsError(try InsightBasalSchedule.simplified(items: [RepeatingScheduleValue(startTime: 600, value: 1.0)]))
        XCTAssertThrowsError(try InsightBasalSchedule.simplified(items: [
            RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 0, value: 1.0)
        ]))
        // 48 half-hour entries (Trio's editor allows them)
        let many = (0 ..< 48).map { RepeatingScheduleValue(startTime: TimeInterval($0 * 1800), value: $0 % 2 == 0 ? 1.0 : 0.9) }
        let m = try InsightBasalSchedule.simplified(items: many)
        XCTAssertEqual(m.schedule.hourlyRates, Array(repeating: 0.9, count: 24))
    }

    func testUncertainOrUnverifiedProfileBlocksTbrUntilResynced() {
        for failure in [BridgeError.timeout, .remote(BridgeRemoteError(code: .verifyFailed, message: "", uncertain: false))] {
            let h = ManagerHarness()
            h.client.profileResult = .failure(failure)
            guard case .failure = h.syncSchedule(items([(0, 0.9)])) else { return XCTFail() }
            XCTAssertFalse(h.state.basalScheduleSynced)
            guard case .configuration? = h.tbr(1.5) else { return XCTFail() }
            XCTAssertTrue(h.client.setTbrCalls.isEmpty)

            // manual re-sync of the desired schedule repairs it
            h.client.profileResult = .success(SetBasalProfileResult(activeProfile: 1))
            let done = expectation(description: "resync")
            h.manager.resyncBasalProfile { _ in done.fulfill() }
            wait(for: [done], timeout: 5)
            h.settle()
            XCTAssertTrue(h.state.basalScheduleSynced)
            XCTAssertEqual(h.state.basalSchedule?.hourlyRates[0], 0.9)
        }
    }

    func testDeliveryLimitsNeverExceedThePumpsOwn() throws {
        let h = ManagerHarness()
        h.client.status = h.status()
        h.ensureData()
        let requested = DeliveryLimits(
            maximumBasalRate: LoopQuantity(unit: DoseEntry.unitsPerHour, doubleValue: 8),
            maximumBolus: LoopQuantity(unit: DoseEntry.units, doubleValue: 20)
        )
        let exp = expectation(description: "limits")
        var result: DeliveryLimits?
        h.manager.syncDeliveryLimits(limits: requested) { if case let .success(l) = $0 { result = l }
            exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(result?.maximumBolus?.doubleValue(for: DoseEntry.units), 10, "pump max bolus is 10")
        XCTAssertEqual(result?.maximumBasalRate?.doubleValue(for: DoseEntry.unitsPerHour), 5)
        XCTAssertEqual(h.state.effectiveMaxBolus, 10)
    }

    func testRoundingHelpersRoundDown() {
        let h = ManagerHarness()
        XCTAssertEqual(h.manager.roundToSupportedBolusVolume(units: 1.97), 1.95)
        XCTAssertEqual(h.manager.roundToSupportedBolusVolume(units: 2.04), 2.0)
        XCTAssertEqual(h.manager.roundToSupportedBolusVolume(units: 0.04), 0)
        XCTAssertEqual(h.manager.roundToSupportedBasalRate(unitsPerHour: 0.019), 0)
        XCTAssertEqual(h.manager.roundToSupportedBasalRate(unitsPerHour: 1.239), 1.23)
        XCTAssertEqual(h.manager.roundToSupportedBasalRate(unitsPerHour: 5.09), 5.0)
        XCTAssertEqual(h.manager.maximumBasalScheduleEntryCount, 24)
        XCTAssertEqual(h.manager.minimumBasalScheduleEntryDuration, 3600)
        XCTAssertEqual(InsightPumpManager.onboardingMaximumBasalScheduleEntryCount, 24)
    }

    func testNotOnboardedPumpDoesNotDose() {
        let h = ManagerHarness { $0.isOnboarded = false }
        guard case .configuration? = h.bolus(1) else { return XCTFail() }
        guard case .configuration? = h.tbr(1.5) else { return XCTFail() }
    }
}
