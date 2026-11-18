@testable import InsightKit
import LoopKit
import XCTest

final class ManagerStatusTests: XCTestCase {
    func testStatusUpdatesStateAndReportsReservoir() {
        let h = ManagerHarness()
        h.client.status = h.status(reservoir: 87.5)
        h.ensureData()
        XCTAssertEqual(h.state.reservoirUnits, 87.5)
        XCTAssertEqual(h.state.batteryPercent, 80)
        XCTAssertEqual(h.manager.status.pumpBatteryChargeRemaining ?? 0, 0.8, accuracy: 1E-9)
        XCTAssertEqual(h.delegate.reservoirReads.last, 87.5)
        XCTAssertNotNil(h.manager.lastSync)
        XCTAssertFalse(h.manager.status.deliveryIsUncertain)
    }

    func testEnsureCurrentPumpDataSkipsWhenFresh() {
        let h = ManagerHarness()
        h.ensureData()
        let calls = h.client.statusCalls
        h.ensureData()
        XCTAssertEqual(h.client.statusCalls, calls, "a status younger than a minute is reused")
        h.advance(120)
        h.ensureData()
        XCTAssertGreaterThan(h.client.statusCalls, calls)
    }

    func testHistoryIsReadIncrementallyAndDeduplicated() {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 103)
        h.client.history = [
            h.historyEvent(101, "tubeFilled", after: -10, #"{"units":5}"#),
            h.historyEvent(102, "cannulaFilled", after: -9, #"{"units":0.5}"#),
            h.historyEvent(103, "cartridgeRemoved", after: -8, "{}")
        ]
        h.ensureData()
        XCTAssertEqual(h.client.historyCalls.first ?? nil, 100, "reads after the stored sequence")
        XCTAssertEqual(h.state.lastHistorySequence, 103)
        XCTAssertEqual(h.delegate.allEvents.filter { $0.type == .prime || $0.type == .rewind }.count, 3)

        h.advance(120)
        h.ensureData()
        XCTAssertEqual(
            h.delegate.allEvents.filter { $0.type == .prime || $0.type == .rewind }.count,
            3,
            "nothing is reported twice"
        )
    }

    func testSequenceIsOnlyStoredAfterLoopAcceptedTheEvents() {
        let h = ManagerHarness()
        h.delegate.failEvents = true
        h.client.status = h.status(historySequence: 101)
        h.client.history = [h.historyEvent(101, "tubeFilled", after: -10, #"{"units":5}"#)]
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 100, "rejected by the delegate -> will be sent again")
        h.delegate.failEvents = false
        h.advance(120)
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 101)
    }

    func testFirstSyncOnlyLooksAtRecentHistory() {
        let h = ManagerHarness { $0.lastHistorySequence = nil }
        h.client.status = h.status(historySequence: 5000)
        h.client.history = [
            h.historyEvent(4990, "tubeFilled", after: -3600 * 20, #"{"units":5}"#),
            h.historyEvent(4999, "cannulaFilled", after: -600, #"{"units":0.5}"#)
        ]
        h.ensureData()
        XCTAssertEqual(h.client.historyCalls.first ?? nil, 4850, "only the last ~150 events are requested")
        XCTAssertEqual(h.delegate.allEvents.filter { $0.type == .prime }.count, 1, "events older than 8 h are ignored")
        XCTAssertEqual(h.state.lastHistorySequence, 4999)
    }

    func testHistoryReadFailureIsNotFatal() {
        let h = ManagerHarness()
        h.client.status = h.status(historySequence: 105)
        h.client.historyResult = .failure(.timeout)
        h.ensureData()
        XCTAssertEqual(h.state.lastHistorySequence, 100)
    }

    func testPumpSerialChangeResetsHistoryAndSchedule() {
        let h = ManagerHarness()
        h.client.status = h.status(serial: "OTHER")
        h.ensureData()
        XCTAssertEqual(h.state.pumpSerial, "OTHER")
        XCTAssertFalse(h.state.basalScheduleSynced)
        XCTAssertTrue(h.state.tempBasals.isEmpty)
    }

    func testSimulatorPumpIsRecognised() {
        let h = ManagerHarness()
        XCTAssertFalse(h.state.isSimulated)
        h.client.status = h.status(serial: "SIMULATOR")
        h.ensureData()
        XCTAssertTrue(h.state.isSimulated)
    }

    func testExternalBolusOnThePumpIsAdopted() {
        let h = ManagerHarness()
        h.client.status = h.status(boluses: [.init(bolusId: 40, type: "standard", amount: 3.0, remaining: 2.0)])
        h.ensureData()
        guard case let .inProgress(dose) = h.manager.status.bolusState else { return XCTFail() }
        XCTAssertEqual(dose.programmedUnits, 3.0)
        XCTAssertTrue(dose.wasProgrammedByPumpUI)
    }

    func testExternalTbrOnThePumpIsAdopted() throws {
        let h = ManagerHarness()
        h.client.status = h.status(tbr: .init(percent: 70, duration: 60, remaining: 50, start: h.now.addingTimeInterval(-600)))
        h.ensureData()
        let tbr = try XCTUnwrap(h.state.runningTempBasal(at: h.now))
        XCTAssertEqual(tbr.percent, 70)
        XCTAssertEqual(tbr.effectiveRate, 0.7, accuracy: 1E-9)
        XCTAssertFalse(tbr.automatic)
        guard case .tempBasal? = h.manager.status.basalDeliveryState else { return XCTFail() }
    }

    func testSuspendedStateAppearsInStatus() {
        let h = ManagerHarness()
        h.client.status = h.status(mode: .paused)
        h.ensureData()
        XCTAssertEqual(h.manager.status.basalDeliveryState.map(\.isSuspended), true)
    }

    func testStaleStatusAndSignalLoss() {
        let h = ManagerHarness()
        h.ensureData()
        XCTAssertFalse(h.manager.inSignalLoss)
        XCTAssertFalse(h.state.isStatusStale(now: h.now))
        XCTAssertTrue(h.state.isStatusStale(now: h.now.addingTimeInterval(16 * 60)))
        h.client.sessionState = .linkConnecting
        h.advance(13 * 60)
        XCTAssertTrue(h.manager.inSignalLoss)
    }

    func testPumpManagerErrorMapping() {
        func map(_ code: BridgeErrorCode, uncertain: Bool = false) -> PumpManagerError {
            InsightPumpManager.pumpManagerError(from: .remote(BridgeRemoteError(code: code, message: "", uncertain: uncertain)))
        }
        if case .deviceState = map(.pumpSuspended) {} else { XCTFail() }
        if case .deviceState = map(.alertActive) {} else { XCTFail() }
        if case .configuration = map(.invalidArgs) {} else { XCTFail() }
        if case .connection = map(.pumpUnreachable) {} else { XCTFail() }
        if case .connection = InsightPumpManager.pumpManagerError(from: .notConnected) {} else { XCTFail() }
    }
}

final class ManagerAlertTests: XCTestCase {
    private let warning = BridgeAlert(alertId: 3, alertType: "W31_CARTRIDGE_LOW", category: .warning)

    func testAlertIsIssuedOnceAndRetractedWhenItClears() async throws {
        let h = ManagerHarness()
        h.client.status = h.status(alert: warning)
        h.ensureData()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.delegate.issuedAlerts.count, 1)
        h.advance(120)
        h.ensureData()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.delegate.issuedAlerts.count, 1, "the same alert is not issued twice")

        h.client.status = h.status(alert: nil)
        h.advance(120)
        h.ensureData()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.delegate.retractedAlerts.count, 1)
        XCTAssertTrue(h.state.activeAlerts.isEmpty)
    }

    func testAcknowledgeConfirmsOnThePump() async throws {
        let h = ManagerHarness()
        h.client.status = h.status(alert: warning)
        h.ensureData()
        let id = try XCTUnwrap(h.state.activeAlerts.first?.loopIdentifier)
        h.client.status = h.status(after: 5, alert: nil)
        try await h.manager.acknowledgeAlert(alertIdentifier: id)
        XCTAssertEqual(h.client.confirmedAlerts, [3])
        XCTAssertTrue(h.state.activeAlerts.isEmpty)
        // unknown identifiers are ignored
        try await h.manager.acknowledgeAlert(alertIdentifier: "nope")
        XCTAssertEqual(h.client.confirmedAlerts, [3])
    }

    func testSnoozedAlertIsNotShown() async throws {
        let h = ManagerHarness()
        h.client.status = h
            .status(alert: BridgeAlert(alertId: 3, alertType: "W31_CARTRIDGE_LOW", category: .warning, status: "snoozed"))
        h.ensureData()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.delegate.issuedAlerts.isEmpty)
    }

    func testSeverityMapping() {
        func level(_ type: String, _ category: BridgeAlertCategory) -> Alert.InterruptionLevel {
            InsightAlertCatalog.loopAlert(for: BridgeAlert(alertId: 1, alertType: type, category: category)).interruptionLevel
        }
        XCTAssertEqual(level("E7_ELECTRONIC_ERROR", .error), .critical)
        XCTAssertEqual(level("ERROR_6", .error), .critical)
        XCTAssertEqual(level("W31_CARTRIDGE_LOW", .warning), .timeSensitive)
        XCTAssertEqual(level("WARNING_32", .warning), .timeSensitive)
        XCTAssertEqual(level("M21_PAUSE_MODE_ACTIVE", .maintenance), .active)
        XCTAssertEqual(level("REMINDER_01", .reminder), .active)
        // category missing: derive from the AAPS name
        XCTAssertEqual(level("E7_ELECTRONIC_ERROR", .unknown), .critical)
        XCTAssertEqual(level("WARNING_36", .unknown), .timeSensitive)
        XCTAssertEqual(level("MAINTENANCE_21", .unknown), .active)
    }

    func testCatalogTextAndCodes() {
        let low = InsightAlertCatalog.info(for: warning)
        XCTAssertEqual(low.code, 31)
        XCTAssertEqual(low.codeLabel, "W31")
        XCTAssertFalse(low.title.isEmpty)
        let error = InsightAlertCatalog.info(for: BridgeAlert(alertId: 1, alertType: "E7_ELECTRONIC_ERROR", category: .error))
        XCTAssertEqual(error.severity, .error)
        XCTAssertEqual(error.codeLabel, "E7")
        let unknown = InsightAlertCatalog.info(for: BridgeAlert(alertId: 1, alertType: "WEIRD", category: .warning))
        XCTAssertNil(unknown.code)
        XCTAssertFalse(unknown.explanation.isEmpty)
        XCTAssertEqual(InsightAlertCatalog.parse(alertType: "MAINTENANCE_21").1, 21)
        XCTAssertEqual(InsightAlertCatalog.parse(alertType: "M21_PAUSE_MODE_ACTIVE").1, 21)
    }
}

final class StateCodingTests: XCTestCase {
    func testRawValueRoundTripOfEveryField() throws {
        var s = InsightPumpManagerState(
            bridgeId: "00112233aabbccdd",
            bridgeName: "InsightBridge-CCDD",
            peripheralIdentifier: UUID().uuidString
        )
        s.bridgeVersion = "1.2"
        s.pumpSerial = "SN"
        s.pumpFirmware = "fw"
        s.isSimulated = true
        s.isOnboarded = true
        s.insulinType = .fiasp
        s.basalSchedule = ManagerHarness.flatSchedule(0.9)
        s.desiredBasalSchedule = ManagerHarness.flatSchedule(1.1)
        s.basalScheduleSynced = true
        s.maxBolus = 8
        s.maxBasal = 3
        s.limits = PumpLimitsState(maxBolus: 10, maxBasal: 5, bolusStep: 0.05, basalStep: 0.01, minBasal: 0.02)
        s.reservoirUnits = 120.5
        s.batteryPercent = 77
        s.operatingMode = .paused
        s.suspendedSince = Date(timeIntervalSince1970: 1000)
        s.pumpLink = .connecting
        s.lastStatusDate = Date(timeIntervalSince1970: 2000)
        s.lastPumpReadDate = Date(timeIntervalSince1970: 1990)
        s.lastBridgeContact = Date(timeIntervalSince1970: 2001)
        s.bridgeBasalRate = 0.9
        s.pumpTimeDriftSeconds = 4
        s.lastTimeSync = Date(timeIntervalSince1970: 500)
        s.pumpTimeZoneOffsetSeconds = 3600
        s.tempBasals = [ActiveTempBasal(
            percent: 120,
            durationMinutes: 30,
            start: Date(timeIntervalSince1970: 3000),
            scheduledRate: 0.9,
            effectiveRate: 1.08,
            decisionId: UUID(),
            automatic: true,
            endedAt: nil
        )]
        s.bolus = UnfinalizedBolus(
            requestId: "r",
            units: 1.5,
            startDate: Date(timeIntervalSince1970: 3100),
            bolusId: 4,
            decisionId: UUID(),
            automatic: false,
            insulinType: "1",
            deliveredUnits: 0.5,
            phase: .inProgress,
            endDate: nil,
            programmedOnPump: false
        )
        s.pendingCommand = PendingCommand(
            kind: .setTBR,
            requestId: "q",
            sentDate: Date(timeIntervalSince1970: 3200),
            baselineSequence: 99,
            units: nil,
            percent: 110,
            durationMinutes: 30,
            scheduledRate: 1,
            decisionId: nil,
            automatic: true,
            insulinType: nil,
            isUncertain: true
        )
        s.lastHistorySequence = 4321
        s.lastHistoryRead = Date(timeIntervalSince1970: 3300)
        s.activeAlerts = [PumpAlertRecord(
            alertId: 3,
            alertType: "W31_CARTRIDGE_LOW",
            category: "warning",
            loopIdentifier: "insight.pump-alert.W31_CARTRIDGE_LOW.3",
            issuedAt: Date(timeIntervalSince1970: 10)
        )]
        s.activePumpAlert = BridgeAlert(alertId: 3, alertType: "W31_CARTRIDGE_LOW", category: .warning)
        s.disconnectAlertIssued = true

        let raw = s.rawValue
        // property-list compatible (what LoopKit persists)
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        let restored = try XCTUnwrap(InsightPumpManagerState(rawValue: try XCTUnwrap(plist)))
        XCTAssertEqual(restored, s)
        XCTAssertEqual(raw["reservoirLevel"] as? Double, 120.5)
        XCTAssertEqual(raw["lastStatusDate"] as? Date, Date(timeIntervalSince1970: 2000))
    }

    func testRawValueNeverContainsSecrets() throws {
        let s = InsightPumpManagerState(bridgeId: "00112233aabbccdd", bridgeName: "n", peripheralIdentifier: nil)
        let data = try XCTUnwrap(s.rawValue["json"] as? Data)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["ltk", "clientid", "secret", "key"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }

    func testInvalidRawStateIsRejected() {
        XCTAssertNil(InsightPumpManagerState(rawValue: [:]))
        XCTAssertNil(InsightPumpManagerState(rawValue: ["version": 1, "json": Data("nope".utf8)]))
        XCTAssertNil(InsightPumpManagerState(rawValue: ["version": 999, "json": Data()]))
        XCTAssertNil(InsightPumpManager(rawState: [:]))
    }

    func testManagerIdentity() {
        let h = ManagerHarness()
        XCTAssertEqual(h.manager.pluginIdentifier, "Insight")
        XCTAssertEqual(h.manager.managerIdentifier, "Insight")
        XCTAssertEqual(InsightPumpManager.pluginIdentifier, "Insight")
        XCTAssertEqual(h.manager.localizedTitle, "Accu-Chek Insight")
        XCTAssertTrue(h.manager.isOnboarded)
        XCTAssertFalse(h.manager.isInoperable)
        XCTAssertFalse(h.manager.pumpRecordsBasalProfileStartEvents)
        XCTAssertEqual(h.manager.rawState["version"] as? Int, 1)
    }

    func testCommandQueueRunsOneAtATime() {
        let queue = DispatchQueue(label: "cq")
        let cq = CommandQueue(queue: queue)
        var log = [String]()
        var releaseFirst: (() -> Void)?
        cq.enqueue("a") { done in log.append("a-start")
            releaseFirst = done }
        cq.enqueue("b") { done in log.append("b-start")
            done() }
        queue.sync {}
        XCTAssertEqual(log, ["a-start"])
        queue.sync { releaseFirst?()
            releaseFirst?() } // double done must not skip ahead
        queue.sync {}
        queue.sync {}
        XCTAssertEqual(log, ["a-start", "b-start"])
    }
}
