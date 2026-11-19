@testable import InsightKit
import LoopKit
import XCTest

/// What Trio needs to loop with this pump, and that every refusal is visible.
final class LoopReadinessTests: XCTestCase {
    private func alerts(_ h: ManagerHarness, _ id: String) -> Int {
        h.delegate.issuedAlerts.filter { $0.identifier.alertIdentifier == id }.count
    }

    // MARK: refusals are never silent

    func testRefusedTempBasalIsReportedOnceAndRetractedWhenDosingWorksAgain() {
        let h = ManagerHarness { $0.basalScheduleSynced = false }
        guard case .configuration? = h.tbr(1.5) else { return XCTFail("temp basal is refused while the profile is unconfirmed") }
        XCTAssertNotNil(h.state.loopBlockedReason)
        XCTAssertTrue(eventually { alerts(h, InsightAlertCatalog.loopBlockedAlertIdentifier) == 1 })
        // The loop retries every 5 minutes: no alert storm
        h.advance(300)
        _ = h.tbr(1.5)
        _ = eventually(0.3) { false }
        XCTAssertEqual(alerts(h, InsightAlertCatalog.loopBlockedAlertIdentifier), 1)
        // After the cooldown the reminder comes again
        h.advance(30 * 60)
        _ = h.tbr(1.5)
        XCTAssertTrue(eventually { alerts(h, InsightAlertCatalog.loopBlockedAlertIdentifier) == 2 })
        // fixed by the user: sync the profile, the next command works and the alert goes away
        XCTAssertNotNil(h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 1.0)]).success)
        h.advance(70)
        h.client.status = h.status(basalRate: 1.0)
        XCTAssertNil(h.tbr(1.5))
        XCTAssertNil(h.state.loopBlockedReason)
        XCTAssertTrue(eventually {
            h.delegate.retractedAlerts.contains { $0.alertIdentifier == InsightAlertCatalog.loopBlockedAlertIdentifier } })
    }

    func testRefusedBolusAndUncertainGateAreReported() {
        let h = ManagerHarness()
        h.makeBolusUncertain()
        guard case .deviceState? = h.bolus(0.5) else { return XCTFail() }
        XCTAssertEqual(h.state.loopBlockedReason, InsightPumpManagerError.deliveryUncertain.errorDescriptionText)
    }

    func testSuspendedPumpIsNotReportedAsABlockedLoop() {
        let h = ManagerHarness { $0.operatingMode = .stopped }
        _ = h.tbr(1.5)
        XCTAssertNil(h.state.loopBlockedReason, "Trio itself skips dosing while suspended; the user knows")
    }

    // MARK: first loop / profile healing

    func testProfileWriteThatDidNotFinishCleanlyIsWrittenAgainByItself() {
        let h = ManagerHarness {
            $0.basalScheduleSynced = false
            $0.profileWriteFailed = true
            $0.desiredBasalSchedule = ManagerHarness.flatSchedule(1.0)
        }
        h.ensureData()
        XCTAssertEqual(h.client.profileCalls.count, 1)
        XCTAssertTrue(h.state.basalScheduleSynced)
        XCTAssertNil(h.state.profileWriteFailed)
    }

    func testProfileIsNotOverwrittenAutomaticallyWithoutAFailedWrite() {
        // e.g. the pump was replaced, or the pump contradicted Trio's profile: the user decides
        let h = ManagerHarness { $0.basalScheduleSynced = false }
        h.ensureData()
        XCTAssertTrue(h.client.profileCalls.isEmpty)
        XCTAssertFalse(h.state.basalScheduleSynced)
    }

    func testAutomaticProfileWriteIsRateLimited() {
        let h = ManagerHarness {
            $0.basalScheduleSynced = false
            $0.profileWriteFailed = true
            $0.desiredBasalSchedule = ManagerHarness.flatSchedule(1.0)
        }
        h.client.profileResult = .failure(.timeout)
        h.ensureData()
        XCTAssertEqual(h.client.profileCalls.count, 1)
        h.advance(70)
        h.ensureData()
        XCTAssertEqual(h.client.profileCalls.count, 1, "not again within 10 minutes")
        h.advance(11 * 60)
        h.ensureData()
        XCTAssertEqual(h.client.profileCalls.count, 2)
    }

    func testSetupWithHalfHourScheduleSucceedsAndTheFirstLoopWorks() {
        let h = ManagerHarness {
            $0.isOnboarded = false
            $0.basalSchedule = nil
            $0.basalScheduleSynced = false
        }
        let items = [
            RepeatingScheduleValue(startTime: 0, value: 1.0),
            RepeatingScheduleValue(startTime: 1800, value: 0.9),
            RepeatingScheduleValue(startTime: 3600, value: 1.0)
        ]
        let done = expectation(description: "setup")
        var failure: Error?
        h.manager.finishSetup(basalItems: items, maxBasal: 3, maxBolus: 5, insulinType: .novolog) { result in
            if case let .failure(error) = result { failure = error }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        h.settle()
        XCTAssertNil(failure)
        XCTAssertTrue(h.state.isOnboarded)
        XCTAssertTrue(h.state.basalScheduleSynced)
        XCTAssertEqual(h.client.timeCalls, 1, "time pushed during setup")
        XCTAssertEqual(h.state.basalSchedule?.hourlyRates[0], 0.9, "minimum of the hour")
        h.advance(70)
        let rate = h.state.basalSchedule!.rate(at: h.now, in: h.state.pumpTimeZone)
        h.client.status = h.status(basalRate: rate)
        XCTAssertNil(h.tbr(rate * 0.5), "no manual step between setup and the first loop")
    }

    // MARK: link status / peripheral persistence

    func testAdoptedPeripheralIdentifierIsPersisted() {
        let h = ManagerHarness()
        let id = UUID()
        h.manager.bridgeClient(h.client, didAdoptPeripheral: id)
        h.settle()
        XCTAssertEqual(h.state.peripheralIdentifier, id.uuidString)
    }

    func testLinkStatusDescribesTheSearch() {
        let now = Date()
        let since = now.addingTimeInterval(-30)
        typealias M = InsightPumpManager
        XCTAssertEqual(M.linkStatus(connection: .ready, lostSince: nil, lastSighting: nil, now: now), .connected)
        XCTAssertEqual(
            M.linkStatus(connection: .linkConnecting, lostSince: since, lastSighting: nil, now: now), .reconnecting(since: since)
        )
        let long = now.addingTimeInterval(-300)
        XCTAssertEqual(
            M.linkStatus(connection: .linkConnecting, lostSince: long, lastSighting: nil, now: now), .bridgeNotFound(since: long),
            "searching for minutes and never saw an advertisement"
        )
        XCTAssertEqual(
            M.linkStatus(connection: .linkConnecting, lostSince: long, lastSighting: now.addingTimeInterval(-10), now: now),
            .reconnecting(since: long), "advertisements are seen: the bridge is around"
        )
        XCTAssertEqual(M.linkStatus(connection: .needsRepair("x"), lostSince: long, lastSighting: nil, now: now), .needsRepair)
        XCTAssertEqual(M.linkStatus(connection: .idle, lostSince: nil, lastSighting: nil, now: now), .idle)
    }

    func testUnreachableAlertIsStillRaisedAfterTenMinutesWithoutSession() {
        let h = ManagerHarness()
        h.client.sessionState = .linkConnecting
        h.manager.bridgeClientDidChangeState(h.client)
        h.settle()
        h.advance(9 * 60)
        XCTAssertEqual(alerts(h, InsightAlertCatalog.disconnectedAlertIdentifier), 0)
        h.advance(2 * 60)
        XCTAssertTrue(eventually { alerts(h, InsightAlertCatalog.disconnectedAlertIdentifier) == 1 })
    }
}

private extension Result {
    var success: Success? { if case let .success(v) = self { return v }
        return nil }
}
