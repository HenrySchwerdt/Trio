@testable import InsightKit
import LoopKit
import XCTest

// MARK: - 1. safety actions never wait for other actions

final class SafetyActionTests: XCTestCase {
    private func make() -> (ManagerHarness, InsightSettingsViewModel) {
        let h = ManagerHarness()
        return (h, InsightSettingsViewModel(manager: h.manager, supportedInsulinTypes: [.novolog]))
    }

    func testSuspendRunsWhileAnotherActionIsBusy() {
        let (h, vm) = make()
        vm.busyAction = .syncBasal
        XCTAssertNil(vm.blockedReason(for: .suspend))
        vm.suspend()
        XCTAssertTrue(eventually { vm.resultMessage != nil })
        XCTAssertEqual(h.client.modeCalls, [.stopped])
        XCTAssertEqual(vm.busyAction, .syncBasal, "the other action keeps its own state")
    }

    func testStopTempBasalIsNeverBlockedByBusyActions() {
        let (_, vm) = make()
        vm.busyAction = .refresh
        XCTAssertNil(vm.blockedReason(for: .stopTempBasal))
        XCTAssertNotNil(vm.blockedReason(for: .syncTime), "ordinary actions still wait")
    }

    func testLateAnswerAfterTheWatchdogNeverClearsANewerRun() {
        let saved = InsightSettingsViewModel.actionWatchdog
        InsightSettingsViewModel.actionWatchdog = 0.15
        defer { InsightSettingsViewModel.actionWatchdog = saved }
        let (h, vm) = make()
        h.client.holdStatus = true
        vm.refresh() // first run, never answered in time
        XCTAssertTrue(eventually { vm.busyAction == nil }, "the watchdog ended the first run")
        vm.resultMessage = nil
        InsightSettingsViewModel.actionWatchdog = 30 // the second run must outlive this test's wait
        vm.refresh() // second run
        XCTAssertEqual(vm.busyAction, .refresh)
        h.client.releaseStatus() // the late answer of the FIRST run
        _ = eventually(0.3) { false }
        XCTAssertEqual(vm.busyAction, .refresh, "a late completion of an older run must not clear the newer run")
    }
}

// MARK: - 4 / 7 / 8. dosing gates

final class ReduceOnlyAndGateTests: XCTestCase {
    private func uncertain(_ s: inout InsightPumpManagerState) {
        s.pendingCommand = PendingCommand(
            kind: .bolus, requestId: "r", sentDate: Date(), baselineSequence: 100, units: 1, percent: nil,
            durationMinutes: nil, scheduledRate: nil, decisionId: nil, automatic: true, insulinType: nil, isUncertain: true
        )
    }

    func testZeroTempBasalIsNotBlockedByUncertainDeliveryOrAnUnconfirmedProfile() {
        let h = ManagerHarness {
            self.uncertain(&$0)
            $0.basalScheduleSynced = false
        }
        XCTAssertNil(h.tbr(0.0))
        XCTAssertEqual(h.client.setTbrCalls.last?.percent, 0)
        XCTAssertEqual(h.state.pendingCommand?.requestId, "r", "the unresolved record is never overwritten")
    }

    func testRaisingTempBasalAndBolusStayBlockedByUncertainDelivery() {
        let h = ManagerHarness { self.uncertain(&$0) }
        XCTAssertNotNil(h.tbr(2.0))
        XCTAssertTrue(h.client.setTbrCalls.isEmpty)
        XCTAssertNotNil(h.bolus(0.5))
        XCTAssertTrue(h.client.deliverBolusCalls.isEmpty)
    }

    func testReducingBelowTheScheduleIsAllowedWhileTheProfileIsUnconfirmedButRaisingIsNot() {
        let h = ManagerHarness { $0.basalScheduleSynced = false }
        XCTAssertNil(h.tbr(0.5))
        XCTAssertEqual(h.client.setTbrCalls.last?.percent, 50)
        guard case .configuration? = h.tbr(1.5) else { return XCTFail("a raise needs the confirmed profile") }
        XCTAssertEqual(h.client.setTbrCalls.count, 1)
    }

    func testReducingIsAllowedDuringABasalMismatchButRaisingIsNot() {
        // the pump says 2.0 U/h, Trio's schedule says 1.0 U/h
        let h = ManagerHarness()
        h.client.status = h.status(basalRate: 2.0)
        h.ensureData()
        XCTAssertNil(h.tbr(0.0), "stopping delivery needs no cross-check")
        h.advance(70)
        h.client.status = h.status(basalRate: 2.0)
        guard case .configuration? = h.tbr(1.5) else { return XCTFail("raise: mismatch gate") }
    }

    func testVerifyFailureDoesNotTriggerAutomaticRewrites() {
        let h = ManagerHarness()
        h.client.profileResult = .failure(.remote(BridgeRemoteError(code: .verifyFailed, message: "x", uncertain: false)))
        _ = h.syncSchedule([RepeatingScheduleValue(startTime: 0, value: 1.1)])
        XCTAssertNil(h.state.profileWriteFailed, "the pump disagrees: the user decides")
        let calls = h.client.profileCalls.count
        h.advance(70)
        h.ensureData()
        XCTAssertEqual(h.client.profileCalls.count, calls)
    }

    func testAutomaticRewritesAreCappedThenTheUserIsTold() {
        let h = ManagerHarness {
            $0.basalScheduleSynced = false
            $0.profileWriteFailed = true
            $0.desiredBasalSchedule = ManagerHarness.flatSchedule(1.0)
        }
        h.client.profileResult = .failure(.timeout)
        for _ in 0 ..< 6 {
            h.ensureData()
            h.advance(11 * 60)
        }
        XCTAssertEqual(h.client.profileCalls.count, InsightPumpManager.maxAutoProfileResyncs)
        XCTAssertNil(h.state.profileWriteFailed)
        XCTAssertTrue(eventually {
            h.delegate.issuedAlerts.contains { $0.identifier.alertIdentifier == InsightAlertCatalog.loopBlockedAlertIdentifier }
        })
    }

    func testNoAutomaticRewriteWhileATempBasalRuns() {
        let h = ManagerHarness()
        XCTAssertNil(h.tbr(1.5))
        h.manager.mutate {
            $0.basalScheduleSynced = false
            $0.profileWriteFailed = true
            $0.desiredBasalSchedule = ManagerHarness.flatSchedule(1.0)
        }
        h.advance(70)
        h.client.status = h.status(tbr: .init(percent: 150, duration: 30, remaining: 20, start: h.now))
        h.ensureData()
        XCTAssertTrue(h.client.profileCalls.isEmpty)
    }
}

// MARK: - 2 / 3 / 5 / 6 + low findings: link and session

final class LinkReviewTests: LinkWorldTestCase {
    private func send(_ op: BridgeOp, _ result: @escaping (Result<BridgeValue, BridgeError>) -> Void = { _ in }) {
        session.send(op, args: BridgeValue.object([:]), completion: result)
        settle()
    }

    // 2. neighbours cannot force a re-pair

    func testNeighbourBridgeRejectsNeverStopTheLink() {
        let stranger = makeBridge(bridgeId: "ffeeddccbbaa9988")
        stranger.bridge.rejectSession = true
        startSession(target: nil)
        for _ in 0 ..< 3 {
            advance(BridgeProtocol.ignoreDuration + 6)
            XCTAssertNotEqual(link.state, .stopped)
            XCTAssertFalse(session.repairSuspected, "only the remembered bridge can raise that suspicion")
            if case .needsRepair = session.state { XCTFail("a neighbour forced needsRepair") }
        }
        XCTAssertGreaterThanOrEqual(central.connectRequestCount(stranger.id), 3, "it keeps looking")
    }

    func testRememberedBridgeRejectingTwiceNeedsRepair() {
        let a = makeBridge()
        a.bridge.rejectSession = true
        startSession(target: a)
        XCTAssertTrue(session.repairSuspected)
        XCTAssertEqual(session.state, .linkConnecting)
        advance(BridgeProtocol.ignoreDuration + 6)
        XCTAssertEqual(session.state, .needsRepair("unknownClient"))
    }

    func testAdvertisementNamingAnotherBridgeIsNotConnectedTo() {
        let other = makeBridge(bridgeId: "ffeeddccbbaa9988")
        other.advertisedId = "9988"
        let paired = makeBridge(inRange: false, advertising: false)
        paired.advertisedId = "CCDD"
        startSession(target: paired)
        XCTAssertEqual(central.connectRequestCount(other.id), 0, "its service data does not match the paired bridge id")
        let rotated = makeBridge()
        rotated.advertisedId = "CCDD"
        advance(BLEBridgeLink.retryInterval)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(targetId, rotated.id)
    }

    // 5. stale verdicts

    func testStaleVerdictsAreIgnored() {
        let a = makeBridge()
        a.bridge.silentHandshake = true
        startSession(target: a)
        let generation = link.connectionGeneration
        XCTAssertEqual(link.state, .connected)
        queue.sync { link.rejectCandidate(connection: generation &- 1) }
        queue.sync { link.markAuthenticated(connection: generation &+ 7) }
        settle()
        XCTAssertEqual(link.ignoredCandidateCount, 0)
        XCTAssertTrue(central.scanning, "not authenticated by a verdict about another connection")
        queue.sync { link.rejectCandidate(connection: generation) }
        settle()
        XCTAssertEqual(link.ignoredCandidateCount, 1, "the verdict for the active connection counts")
    }

    // 6. silent candidates, candidate cap

    func testSilentNonTargetCandidateIsSkippedForTwoMinutes() {
        let silent = makeBridge()
        silent.bridge.silentHandshake = true
        startSession(target: nil)
        advance(BridgeProtocol.handshakeTimeout + 1)
        XCTAssertEqual(central.connectRequestCount(silent.id), 1)
        advance(100)
        XCTAssertEqual(central.connectRequestCount(silent.id), 1, "skipped while on the short ignore list")
        advance(40)
        XCTAssertGreaterThanOrEqual(central.connectRequestCount(silent.id), 2)
    }

    func testSilentRememberedBridgeIsRetriedAtOnce() {
        let a = makeBridge()
        a.bridge.silentHandshake = true
        startSession(target: a)
        advance(BridgeProtocol.handshakeTimeout + 2)
        XCTAssertGreaterThanOrEqual(central.connectRequestCount(a.id), 2)
        XCTAssertEqual(link.ignoredCandidateCount, 0)
    }

    func testStaleCandidatesNeverKeepTheRealBridgeOut() {
        let target = makeBridge(inRange: false, advertising: false)
        let ghosts = (0 ..< 3).map { _ in makeBridge(inRange: false) }
        let real = makeBridge(advertising: false)
        startSession(target: target)
        for ghost in ghosts {
            XCTAssertEqual(central.connectRequestCount(ghost.id), 1, "the target's pending connect is no candidate") }
        ghosts.forEach { $0.advertising = false } // stale entries: their addresses are gone
        real.advertising = true
        advance(BLEBridgeLink.retryInterval) // cap full of fresh ghosts
        XCTAssertNotEqual(session.state, .ready)
        advance(BLEBridgeLink.candidateConnectTimeout + 2 * BLEBridgeLink.retryInterval)
        XCTAssertEqual(session.state, .ready, "ghosts were pruned, the real bridge got in")
        XCTAssertEqual(targetId, real.id)
    }

    // low findings

    func testReadyCandidatesThatBecomeUnusableAreCancelled() {
        let s1 = makeBridge()
        let s2 = makeBridge()
        s1.bridge.silentHandshake = true
        s2.bridge.silentHandshake = true
        startSession(target: nil)
        XCTAssertEqual(link.state, .connected)
        let generation = link.connectionGeneration
        link.allowsCandidates = false
        queue.sync { link.abandonCandidate(connection: generation) }
        settle()
        XCTAssertTrue(central.cancelled.contains(s1.id) && central.cancelled.contains(s2.id), "no connection is left dangling")
    }

    func testSynchronousReadyDuringConnectIsHandled() {
        central.syncReady = true
        let a = makeBridge()
        startSession(target: a)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(targetId, a.id)
    }

    func testPeripheralCacheIsPrunedToWhatIsInUse() {
        let a = makeBridge(inRange: false, advertising: false)
        startSession(target: a)
        advance(BLEBridgeLink.retryInterval)
        XCTAssertTrue(central.lastPruneKeep.contains(a.id))
        XCTAssertLessThanOrEqual(central.lastPruneKeep.count, 1)
    }

    // 3. liveness vs. running requests

    func testNoPingWhileARequestIsPending() {
        let a = makeBridge()
        startSession(target: a)
        a.bridge.handler = { op, _ in op == "getStatus" ? .silent : .ok(.object([:])) }
        advance(55)
        send(.getStatus)
        advance(6)
        XCTAssertEqual(a.bridge.count("ping"), 0, "a running request proves liveness by itself")
        XCTAssertEqual(a.bridge.count("hello"), 1)
    }

    func testPingTimeoutNeverFailsARunningDosingRequest() {
        let a = makeBridge()
        startSession(target: a)
        a.bridge.handler = { op, _ in (op == "ping" || op == "deliverBolus") ? .silent : .ok(.object([:])) }
        advance(BridgeProtocol.pingInterval)
        XCTAssertEqual(a.bridge.count("ping"), 1)
        var result: Result<BridgeValue, BridgeError>?
        send(.deliverBolus) { result = $0 }
        advance(BridgeProtocol.pingTimeout + 1)
        XCTAssertNil(result, "the ping timed out but the dosing request is decided by its own timeout")
        XCTAssertEqual(a.bridge.count("hello"), 1, "link not reset under a running dosing command")
        advance(BridgeProtocol.dosingTimeout)
        if case .failure(.timeout)? = result {} else { XCTFail("\(String(describing: result))") }
    }

    func testAnyMessageDuringAPingProvesLiveness() {
        let a = makeBridge()
        startSession(target: a)
        a.bridge.handler = { op, _ in op == "ping" ? .silent : .ok(.object([:])) }
        advance(BridgeProtocol.pingInterval)
        a.bridge.sendEvent("noop", .object([:]))
        advance(BridgeProtocol.pingTimeout + 1)
        XCTAssertEqual(a.bridge.count("hello"), 1, "an event arrived: the link is alive")
        XCTAssertEqual(session.state, .ready)
    }

    func testWakeUpDoesNotTimeOutAPendingPingFromTheSuspendedPeriod() {
        let a = makeBridge()
        startSession(target: a)
        a.bridge.handler = { op, _ in op == "ping" ? .silent : .ok(.object([:])) }
        advance(BridgeProtocol.pingInterval) // ping pending, 10 s timeout armed
        advance(8)
        session.ensureStarted() // wake-up: the timeout starts again from now
        settle()
        advance(5) // 13 s after the ping, but only 5 s after the wake-up
        XCTAssertEqual(a.bridge.count("hello"), 1)
        a.bridge.handler = { _, _ in .ok(.object([:])) }
        advance(6)
        XCTAssertEqual(a.bridge.count("hello"), 2, "still unanswered 10 s after waking: now the link is dropped")
    }
}
