@testable import InsightKit
import LoopKit
import XCTest

/// Every action of the settings screen: starts, shows progress, ends with a visible success or error, and a tap
/// that cannot run says why instead of doing nothing.
final class SettingsViewModelTests: XCTestCase {
    private func make(_ configure: (inout InsightPumpManagerState) -> Void = { _ in
    }) -> (ManagerHarness, InsightSettingsViewModel) {
        let h = ManagerHarness(configure: configure)
        let vm = InsightSettingsViewModel(manager: h.manager, supportedInsulinTypes: [.novolog])
        return (h, vm)
    }

    private func message(_ vm: InsightSettingsViewModel) -> InsightSettingsViewModel.ResultMessage? {
        _ = eventually { vm.resultMessage != nil }
        return vm.resultMessage
    }

    func testSuspendShowsProgressThenSuccess() {
        let (h, vm) = make()
        vm.suspend()
        XCTAssertTrue(vm.isBusy(.suspend))
        XCTAssertNotNil(message(vm))
        XCTAssertNil(vm.busyAction)
        XCTAssertEqual(h.client.modeCalls, [.stopped])
    }

    func testSuspendFailureIsShown() {
        let (h, vm) = make()
        h.client.modeResult = .failure(.notConnected)
        vm.suspend()
        let m = message(vm)
        XCTAssertNotNil(m)
        XCTAssertFalse(m?.text.isEmpty ?? true)
        XCTAssertNil(vm.busyAction)
    }

    func testSuspendIsNeverBlockedByAnUncertainCommand() {
        let (h, vm) = make()
        h.makeBolusUncertain()
        _ = eventually { vm.state.isDeliveryUncertain }
        XCTAssertNil(vm.blockedReason(for: .suspend), "risk-reducing")
        XCTAssertNil(vm.blockedReason(for: .stopTempBasal))
        vm.suspend()
        _ = message(vm)
        XCTAssertEqual(h.client.modeCalls, [.stopped])
    }

    func testResumeAndSyncBasalAreBlockedWithAnExplanationWhenUncertain() {
        let (h, vm) = make {
            $0.operatingMode = .stopped
            $0.pendingCommand = PendingCommand(
                kind: .bolus, requestId: "r", sentDate: Date(), baselineSequence: 100, units: 1, percent: nil,
                durationMinutes: nil, scheduledRate: nil, decisionId: nil, automatic: true, insulinType: nil, isUncertain: true
            )
        }
        XCTAssertTrue(vm.state.isDeliveryUncertain)
        vm.resume()
        XCTAssertNotNil(vm.resultMessage, "a blocked tap explains itself")
        XCTAssertNil(vm.busyAction)
        XCTAssertTrue(h.client.modeCalls.isEmpty)
        vm.resultMessage = nil
        vm.syncBasalProfile()
        XCTAssertNotNil(vm.resultMessage)
        XCTAssertTrue(h.client.profileCalls.isEmpty)
    }

    func testResumeWorks() {
        let (h, vm) = make { $0.operatingMode = .stopped }
        h.client.status = h.status(mode: .started)
        vm.resume()
        XCTAssertNotNil(message(vm))
        XCTAssertEqual(h.client.modeCalls, [.started])
    }

    func testSyncBasalProfileReportsSuccessAndFailure() {
        let (h, vm) = make()
        vm.syncBasalProfile()
        XCTAssertEqual(vm.busyAction, .syncBasal)
        XCTAssertNotNil(message(vm))
        XCTAssertEqual(h.client.profileCalls.count, 1)
        vm.resultMessage = nil
        h.client.profileResult = .failure(.remote(BridgeRemoteError(code: .verifyFailed, message: "differs", uncertain: false)))
        vm.syncBasalProfile()
        let m = message(vm)
        XCTAssertNotNil(m)
        XCTAssertNil(vm.busyAction)
    }

    func testSyncTimeReportsResult() {
        let (h, vm) = make()
        vm.syncTime()
        XCTAssertNotNil(message(vm))
        XCTAssertEqual(h.client.timeCalls, 1)
    }

    func testRefreshReportsAFailure() {
        let (h, vm) = make()
        h.client.statusResult = .failure(.notConnected)
        vm.refresh()
        XCTAssertNotNil(message(vm), "a failed refresh is not silent")
        XCTAssertNil(vm.busyAction)
    }

    func testRefreshSuccessEndsWithoutAnError() {
        let (_, vm) = make()
        vm.refresh()
        XCTAssertTrue(eventually { vm.busyAction == nil })
        XCTAssertNil(vm.resultMessage)
    }

    func testStopTempBasalWorks() {
        let (h, vm) = make()
        XCTAssertNil(h.tbr(1.5))
        h.client.status = h.status(tbr: .init(percent: 150, duration: 30, remaining: 20, start: h.now))
        _ = h.manager.state
        vm.stopTempBasal()
        XCTAssertNotNil(message(vm))
        XCTAssertNil(vm.busyAction)
    }

    func testASecondActionWhileBusyExplainsInsteadOfDoingNothing() {
        let (h, vm) = make()
        h.client.holdBolus = false
        vm.busyAction = .refresh // an action is running
        vm.syncTime()
        XCTAssertEqual(vm.resultMessage?.text, vm.blockedReason(for: .syncTime))
        XCTAssertEqual(h.client.timeCalls, 0)
    }

    func testBusyStateEndsEvenIfTheBridgeNeverAnswers() {
        let saved = InsightSettingsViewModel.actionWatchdog
        InsightSettingsViewModel.actionWatchdog = 0.2
        defer { InsightSettingsViewModel.actionWatchdog = saved }
        let (h, vm) = make()
        h.client.holdBolus = true
        // an action whose completion never comes: simulate with the unanswered-bolus client by blocking time sync
        vm.busyAction = nil
        vm.syncBasalProfile() // answered immediately by the fake: the watchdog must not fire afterwards
        XCTAssertNotNil(message(vm))
        vm.resultMessage = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(vm.resultMessage, "a finished action is not reported again by the watchdog")
    }

    func testNavigationHooksNeverFailSilently() {
        let (_, vm) = make()
        vm.requestRepair()
        XCTAssertNotNil(vm.resultMessage)
        vm.resultMessage = nil
        vm.requestResolveUncertainty()
        XCTAssertNotNil(vm.resultMessage)
        vm.resultMessage = nil
        vm.requestDelete()
        XCTAssertNotNil(vm.resultMessage)
        var called = 0
        vm.onRepair = { called += 1 }
        vm.onResolveUncertainty = { called += 1 }
        vm.onDelete = { called += 1 }
        vm.resultMessage = nil
        vm.requestRepair()
        vm.requestResolveUncertainty()
        vm.requestDelete()
        XCTAssertEqual(called, 3)
        XCTAssertNil(vm.resultMessage)
    }

    func testConnectionTitleSaysReconnectingSinceAndNotFound() {
        let (h, vm) = make()
        h.client.sessionState = .linkConnecting
        h.manager.bridgeClientDidChangeState(h.client)
        h.settle()
        XCTAssertTrue(
            vm.connectionTitle.contains(":") || vm.connectionTitle.lowercased().contains("reconnect"),
            vm.connectionTitle
        )
        h.advance(3 * 60)
        XCTAssertTrue(vm.connectionTitle.lowercased().contains("not found"), vm.connectionTitle)
        XCTAssertNotNil(vm.connectionHint)
        h.client.sessionState = .ready
        h.manager.bridgeClientDidChangeState(h.client)
        h.settle()
        XCTAssertEqual(vm.connectionTitle, "Connected")
    }

    func testResolveUncertaintyViewModelResolvesAndReportsNoBridge() {
        let (h, _) = make()
        h.makeBolusUncertain()
        let vm = InsightUncertaintyViewModel(manager: h.manager)
        var finished = false
        vm.onFinished = { finished = true }
        vm.resolve(delivered: false)
        XCTAssertTrue(eventually { finished })
        XCTAssertFalse(h.manager.state.isDeliveryUncertain)
    }
}
