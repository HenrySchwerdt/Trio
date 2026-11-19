@testable import InsightKit
import XCTest

final class ModelCodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ string: String) throws -> T {
        try BridgeJSON.decode(type, from: json(string))
    }

    // MARK: request arguments (exact wire names)

    func testRequestArgumentsEncoding() throws {
        func encoded<T: Encodable>(_ value: T) throws -> BridgeValue { try BridgeJSON.toValue(value) }
        XCTAssertEqual(try encoded(HelloArgs(app: "Trio 1.0")), json(#"{"protocol":2,"app":"Trio 1.0"}"#))
        XCTAssertEqual(try encoded(DeliverBolusArgs(amount: 1.25, requestId: "r")), json(#"{"amount":1.25,"requestId":"r"}"#))
        XCTAssertEqual(try encoded(CancelBolusArgs(bolusId: 4)), json(#"{"bolusId":4}"#))
        XCTAssertEqual(
            try encoded(SetTBRArgs(percent: 120, duration: 30, requestId: "r")),
            json(#"{"percent":120,"duration":30,"requestId":"r"}"#)
        )
        XCTAssertEqual(try encoded(RequestIdArgs(requestId: "r")), json(#"{"requestId":"r"}"#))
        XCTAssertEqual(
            try encoded(SetOperatingModeArgs(mode: .stopped, requestId: "r")),
            json(#"{"mode":"stopped","requestId":"r"}"#)
        )
        XCTAssertEqual(
            try encoded(SetBasalProfileArgs(segments: [
                BasalSegment(duration: 720, rate: 0.9),
                BasalSegment(duration: 720, rate: 1.1)
            ], requestId: "r")),
            json(#"{"segments":[{"duration":720,"rate":0.9},{"duration":720,"rate":1.1}],"requestId":"r"}"#)
        )
        XCTAssertEqual(
            try encoded(SetDateTimeArgs(utc: date("2026-11-18T10:00:00Z"), tzOffsetMinutes: 60)),
            json(#"{"utc":"2026-11-18T10:00:00Z","tzOffsetMinutes":60}"#)
        )
        XCTAssertEqual(
            try encoded(AlertRefArgs(alertId: 3, alertType: "W31_CARTRIDGE_LOW")),
            json(#"{"alertId":3,"alertType":"W31_CARTRIDGE_LOW"}"#)
        )
        XCTAssertEqual(try encoded(EmptyArgs()), json("{}"))
    }

    func testReadHistoryArgsSendExplicitNullAndCapPageSize() throws {
        let first = try BridgeJSON.toValue(ReadHistoryArgs(sinceSequence: nil, max: 500))
        XCTAssertEqual(first, json(#"{"sinceSequence":null,"max":50}"#))
        let next = try BridgeJSON.toValue(ReadHistoryArgs(sinceSequence: 41, max: 50))
        XCTAssertEqual(next, json(#"{"sinceSequence":41,"max":50}"#))
    }

    func testEveryOpHasTimeoutClass() {
        for op in BridgeOp.allCases {
            XCTAssertEqual(op.timeout, op == .ping ? 10 : (op.isDosing ? 45 : 30), "\(op)")
        }
        XCTAssertTrue(BridgeOp.deliverBolus.isDosing)
        XCTAssertTrue(BridgeOp.setTBR.isDosing)
        XCTAssertFalse(BridgeOp.getStatus.isDosing)
        XCTAssertFalse(BridgeOp.readHistory.isDosing)
    }

    // MARK: results

    func testOperationResults() throws {
        let hello = try decode(HelloResult.self, #"{"protocol":2,"bridgeVersion":"0.3","pumpPaired":true}"#)
        XCTAssertEqual(hello.bridgeVersion, "0.3")
        XCTAssertTrue(hello.pumpPaired)
        XCTAssertEqual(
            try decode(DeliverBolusResult.self, #"{"bolusId":12,"amount":2.0}"#),
            DeliverBolusResult(bolusId: 12, amount: 2.0)
        )
        XCTAssertEqual(try decode(CancelBolusResult.self, #"{"delivered":0.55}"#).delivered, 0.55)
        XCTAssertNil(try decode(CancelBolusResult.self, #"{"delivered":null}"#).delivered)
        XCTAssertEqual(try decode(SetTBRResult.self, #"{"percent":120,"duration":60}"#), SetTBRResult(percent: 120, duration: 60))
        XCTAssertEqual(try decode(OperatingModeResult.self, #"{"mode":"stopped"}"#).mode, "stopped")
        XCTAssertEqual(try decode(SetBasalProfileResult.self, #"{"activeProfile":1}"#).activeProfile, 1)
        _ = try decode(EmptyResult.self, "{}")
        let pairing = try decode(PumpPairingStatusResult.self, #"{"paired":true,"serial":"123","bridgeBluetoothOn":true}"#)
        XCTAssertEqual(pairing.serial, "123")
        XCTAssertNil(
            try decode(PumpPairingStatusResult.self, #"{"paired":false,"serial":null,"bridgeBluetoothOn":false}"#)
                .serial
        )
    }

    func testFullStatusDecoding() throws {
        let status = try decode(BridgeStatus.self, """
        {"timestamp":"2026-11-18T10:00:00Z","pumpLink":"connected","serial":"SN","firmware":"3.1",
         "operatingMode":"started","battery":{"percent":80},
         "reservoir":{"units":123.45,"cartridgeType":"prefilled"},"basal":{"activeProfile":1,"rate":0.85},
         "tbr":{"percent":120,"duration":60,"remaining":42,"start":"2026-11-18T09:42:00Z"},
         "boluses":[{"bolusId":12,"type":"standard","amount":2.0,"remaining":0.6}],
         "pumpTime":{"utc":"2026-11-18T10:00:00Z","pumpLocal":"2026-11-18T11:00:00","driftSeconds":3},
         "limits":{"maxBolus":10.0,"maxBasal":2.5,"bolusStep":0.05,"basalStep":0.01,"minBasal":0.02},
         "activeAlert":{"alertId":3,"alertType":"W31_CARTRIDGE_LOW","category":"warning","status":"active","tbrPercent":null,"remainingInsulin":null},
         "lastHistorySequence":9876,"futureField":{"x":1}}
        """)
        XCTAssertEqual(status.pumpLink, .connected)
        XCTAssertEqual(status.operatingMode, .started)
        XCTAssertEqual(status.battery?.percent, 80)
        XCTAssertEqual(status.reservoir?.units, 123.45)
        XCTAssertEqual(status.basal?.rate, 0.85)
        XCTAssertEqual(status.tbr?.percent, 120)
        XCTAssertEqual(status.tbr?.start, date("2026-11-18T09:42:00Z"))
        XCTAssertEqual(status.boluses.first?.remaining, 0.6)
        XCTAssertEqual(status.pumpTime?.driftSeconds, 3)
        XCTAssertEqual(status.limits?.bolusStep, 0.05)
        XCTAssertEqual(status.activeAlert?.alertType, "W31_CARTRIDGE_LOW")
        XCTAssertEqual(status.activeAlert?.category, .warning)
        XCTAssertEqual(status.lastHistorySequence, 9876)
    }

    func testStatusWithNullsAndUnknownValues() throws {
        let status = try decode(BridgeStatus.self, """
        {"timestamp":null,"pumpLink":"somethingNew","serial":null,"firmware":null,"operatingMode":"weird",
         "battery":null,"reservoir":{"units":null,"cartridgeType":null},"basal":null,"tbr":null,"boluses":[],
         "pumpTime":null,"limits":null,"activeAlert":null,"lastHistorySequence":null}
        """)
        XCTAssertNil(status.timestamp)
        XCTAssertEqual(status.pumpLink, .unknown)
        XCTAssertEqual(status.operatingMode, .unknown)
        XCTAssertNil(status.reservoir?.units)
        XCTAssertNil(status.tbr)
        XCTAssertEqual(try decode(BridgeStatus.self, "{}").pumpLink, .unknown)
    }

    func testDateParsingAcceptsFractionalSeconds() {
        XCTAssertEqual(BridgeDate.parse("2026-11-18T10:00:00Z"), BridgeDate.parse("2026-11-18T10:00:00.000Z"))
        XCTAssertNil(BridgeDate.parse("yesterday"))
    }

    // MARK: history

    func testEveryHistoryEventTypeDecodes() throws {
        let page = try decode(HistoryResult.self, """
        {"events":[
         {"seq":1,"time":"2026-11-18T10:00:00Z","type":"bolusProgrammed","data":{"bolusId":1,"bolusType":"standard","amount":1.0}},
         {"seq":2,"time":"2026-11-18T10:01:00Z","type":"bolusDelivered","data":{"bolusId":1,"bolusType":"standard","programmed":1.0,"delivered":1.0,"start":"2026-11-18T10:00:00Z","end":"2026-11-18T10:00:40Z"}},
         {"seq":3,"time":"2026-11-18T10:02:00Z","type":"tbrStart","data":{"percent":120,"duration":30}},
         {"seq":4,"time":"2026-11-18T10:32:00Z","type":"tbrEnd","data":{"percent":120,"duration":30}},
         {"seq":5,"time":"2026-11-18T10:33:00Z","type":"basalRateChanged","data":{"oldRate":0.8,"newRate":0.9}},
         {"seq":6,"time":"2026-11-18T10:34:00Z","type":"operatingModeChanged","data":{"oldMode":"started","newMode":"stopped"}},
         {"seq":7,"time":"2026-11-18T10:35:00Z","type":"cartridgeInserted","data":{"units":160}},
         {"seq":8,"time":"2026-11-18T10:36:00Z","type":"cartridgeRemoved","data":{}},
         {"seq":9,"time":"2026-11-18T10:37:00Z","type":"tubeFilled","data":{"units":18}},
         {"seq":10,"time":"2026-11-18T10:38:00Z","type":"cannulaFilled","data":{"units":0.5}},
         {"seq":11,"time":"2026-11-18T10:39:00Z","type":"totalDailyDose","data":{"basal":10,"bolus":12,"total":22,"date":"2026-11-17"}},
         {"seq":12,"time":"2026-11-18T10:40:00Z","type":"alert","data":{"alertId":3,"alertType":"W31_CARTRIDGE_LOW","category":"warning"}},
         {"seq":13,"time":"2026-11-18T10:41:00Z","type":"dateTimeChanged","data":{"old":"a","new":"b"}},
         {"seq":14,"time":"2026-11-18T10:42:00Z","type":"other","data":{"raw":"PowerUp"}},
         {"seq":15,"time":"2026-11-18T10:43:00Z","type":"brandNewType","data":null}
        ],"lastSequence":15,"more":true}
        """)
        XCTAssertEqual(page.events.count, 15)
        XCTAssertEqual(page.events.map(\.kind), [
            .bolusProgrammed, .bolusDelivered, .tbrStart, .tbrEnd, .basalRateChanged, .operatingModeChanged,
            .cartridgeInserted, .cartridgeRemoved, .tubeFilled, .cannulaFilled, .totalDailyDose, .alert,
            .dateTimeChanged, .other, .other
        ])
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.lastSequence, 15)
        XCTAssertEqual(page.events[1].number("delivered"), 1.0)
        XCTAssertEqual(page.events[1].date("end"), date("2026-11-18T10:00:40Z"))
    }

    func testMalformedHistoryEventIsSkippedNotFatal() throws {
        let page = try decode(HistoryResult.self, """
        {"events":[{"seq":1,"time":"2026-11-18T10:00:00Z","type":"tbrEnd","data":{}},
                   {"seq":"x","time":"bad","type":1},
                   {"seq":3,"time":"2026-11-18T10:00:00Z","type":"tbrEnd"}],"lastSequence":3}
        """)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.skippedEvents, 1)
        XCTAssertFalse(page.more)
    }

    // MARK: alerts, events, errors

    func testAlertAndEventsDecoding() throws {
        let alert = try decode(
            BridgeAlert.self,
            #"{"alertId":9,"alertType":"E7_ELECTRONIC_ERROR","category":"error","status":"snoozed","tbrPercent":80,"remainingInsulin":12.5}"#
        )
        XCTAssertEqual(alert.category, .error)
        XCTAssertTrue(alert.isSnoozed)
        XCTAssertEqual(alert.tbrPercent, 80)
        XCTAssertEqual(alert.remainingInsulin, 12.5)
        XCTAssertEqual(try decode(BridgeAlert.self, #"{"alertId":1,"alertType":"X","category":"strange"}"#).category, .unknown)
        XCTAssertEqual(
            try decode(BolusProgress.self, #"{"bolusId":2,"delivered":0.4,"remaining":0.6}"#),
            BolusProgress(bolusId: 2, delivered: 0.4, remaining: 0.6)
        )
    }

    func testRemoteErrorCodes() throws {
        for code in [
            "notPaired",
            "pumpUnreachable",
            "pumpSuspended",
            "pumpBusy",
            "invalidArgs",
            "limitExceeded",
            "verifyFailed",
            "alertActive",
            "busy",
            "tooLarge",
            "unsupportedProtocol",
            "internal"
        ] {
            let e = try decode(BridgeRemoteError.self, #"{"code":"\#(code)","message":"m","uncertain":false}"#)
            XCTAssertEqual(e.code.rawValue, code)
            XCTAssertFalse(e.uncertain)
        }
        let unknown = try decode(BridgeRemoteError.self, #"{"code":"brandNew","message":"m","uncertain":true}"#)
        XCTAssertEqual(unknown.code, .unknown)
        XCTAssertTrue(unknown.uncertain)
        // Missing `uncertain` is not uncertain; missing everything still decodes.
        XCTAssertFalse(try decode(BridgeRemoteError.self, #"{"code":"busy"}"#).uncertain)
    }

    func testUncertaintyClassification() {
        XCTAssertTrue(BridgeError.timeout.isUncertainOutcome)
        XCTAssertTrue(BridgeError.linkLost.isUncertainOutcome)
        XCTAssertTrue(
            BridgeError.remote(BridgeRemoteError(code: .pumpUnreachable, message: "", uncertain: true))
                .isUncertainOutcome
        )
        XCTAssertFalse(
            BridgeError.remote(BridgeRemoteError(code: .pumpSuspended, message: "", uncertain: false))
                .isUncertainOutcome
        )
        XCTAssertFalse(BridgeError.notConnected.isUncertainOutcome, "nothing was sent")
        XCTAssertFalse(BridgeError.encoding("x").isUncertainOutcome)
    }

    func testBridgeValueRoundTrip() throws {
        let v = json(#"{"a":[1,2.5,"x",null,true],"b":{"c":false}}"#)
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(BridgeValue.self, from: data), v)
        XCTAssertEqual(v["b"]?["c"]?.boolValue, false)
    }
}
