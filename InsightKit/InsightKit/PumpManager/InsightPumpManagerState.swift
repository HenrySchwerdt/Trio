import Foundation
import LoopKit

/// A temporary basal that is (believed to be) running on the pump.
public struct ActiveTempBasal: Codable, Equatable {
    public var percent: Int
    public var durationMinutes: Int
    public var start: Date
    public var scheduledRate: Double
    public var effectiveRate: Double
    public var decisionId: UUID?
    public var automatic: Bool
    /// Set when the TBR is known to have ended early (cancelled / replaced); history confirms it later.
    public var endedAt: Date?
    /// The scheduled rates in force when the TBR was set. The pump keeps the *percentage*, so doses must be
    /// computed against this snapshot, never against a schedule that was changed afterwards.
    public var schedule: InsightBasalSchedule?
    /// Pump clock offset from UTC when the TBR was set (hour boundaries are on the pump's clock).
    public var utcOffsetSeconds: Int?
    /// The profile was rewritten while this TBR ran (the pump keeps the percentage): rates from this moment on
    /// come from `laterSchedule`.
    public var laterSchedule: InsightBasalSchedule?
    public var laterScheduleFrom: Date?

    public var plannedEnd: Date { start.addingTimeInterval(TimeInterval(durationMinutes) * 60) }
    public var end: Date { min(endedAt ?? plannedEnd, plannedEnd) }

    public func isRunning(at now: Date) -> Bool { endedAt == nil && plannedEnd > now }

    /// Rates/units of this TBR up to `until` (defaults to its end), per schedule segment.
    public func accounting(until: Date? = nil) -> TempBasalAccounting.Result {
        TempBasalAccounting.account(
            percent: percent, start: start, end: until ?? end, schedule: schedule,
            utcOffset: utcOffsetSeconds ?? 0, fallbackRate: scheduledRate,
            laterSchedule: laterSchedule, laterScheduleFrom: laterScheduleFrom
        )
    }

    /// Stable identifier shared by the local record, its finalized copy and the history event.
    public func syncKey(serial: String) -> String {
        "insight:\(serial):tbr:\(start.epochSeconds):\(percent)"
    }
}

/// A dose we finalized ourselves because the history stayed silent. Kept so that a history event arriving later
/// is recognised as the same dose (same sync identifier) instead of being counted a second time.
public struct FinalizedLocalDose: Codable, Equatable {
    public enum Kind: String, Codable { case bolus, tempBasal }

    public var kind: Kind
    public var key: String
    public var start: Date
    public var end: Date
    public var bolusId: Int?
    public var units: Double?
    public var percent: Int?
    public var finalizedAt: Date
}

public struct ScheduleRevision: Codable, Equatable {
    public var effectiveFrom: Date
    public var schedule: InsightBasalSchedule
}

/// A bolus we started (or may have started) and have not yet reconciled with the pump history.
public struct UnfinalizedBolus: Codable, Equatable {
    public enum Phase: String, Codable { case inProgress, finished }

    public var requestId: String
    public var units: Double
    public var startDate: Date
    public var bolusId: Int?
    public var decisionId: UUID?
    public var automatic: Bool
    public var insulinType: String?
    public var deliveredUnits: Double
    public var phase: Phase
    /// Set when we know the bolus is no longer running (cancelled / completed).
    public var endDate: Date?
    /// The bolus was started by the pump itself or another controller.
    public var programmedOnPump: Bool
    /// When the bridge answered `deliverBolus` (statuses read before that cannot tell anything about it).
    public var acceptedAt: Date?
    /// Consecutive status reads (taken after `acceptedAt`) that did not list this bolus.
    public var missCount = 0
    /// The pump confirmed that this bolus was cancelled: it cannot be running any more.
    public var stopped = false

    /// When the delivery should be over according to the programmed amount.
    public var plannedEnd: Date {
        startDate.addingTimeInterval(InsightPumpManager.deliveryDuration(units: units))
    }

    public var expectedEnd: Date { endDate ?? plannedEnd }

    /// Stable identifier shared by local records and the history event.
    public func syncKey(serial: String) -> String {
        if let bolusId { return "insight:\(serial):bolus:\(bolusId)" }
        return "insight-local:\(serial):bolus:\(requestId)"
    }
}

/// A dosing command whose outcome we do not know. While one exists, **no further dosing happens**.
public struct PendingCommand: Codable, Equatable {
    public enum Kind: String, Codable { case bolus, setTBR, cancelTBR, suspend, resume }

    public var kind: Kind
    public var requestId: String
    public var sentDate: Date
    /// History sequence at the time of sending: anything newer may belong to this command.
    public var baselineSequence: Int?
    public var units: Double?
    public var percent: Int?
    public var durationMinutes: Int?
    public var scheduledRate: Double?
    public var decisionId: UUID?
    public var automatic: Bool
    public var insulinType: String?
    /// False while the command is still in flight in this process, true once timed out / uncertain / app restarted.
    public var isUncertain: Bool
    /// The history already delivered the dose of this (uncertain) command: do not also assume it was given.
    public var historyMatched = false
}

public struct PumpAlertRecord: Codable, Equatable {
    public var alertId: Int
    public var alertType: String
    public var category: String
    public var loopIdentifier: String
    public var issuedAt: Date
}

public struct PumpLimitsState: Codable, Equatable {
    public var maxBolus: Double?
    public var maxBasal: Double?
    public var bolusStep: Double?
    public var basalStep: Double?
    public var minBasal: Double?
}

public struct InsightPumpManagerState: RawRepresentable, Codable, Equatable {
    public typealias RawValue = PumpManager.RawStateValue

    static let currentVersion = 1

    // Bridge identity (the LTK and clientId live in the Keychain, never here)
    public var bridgeId: String?
    public var bridgeName: String?
    public var peripheralIdentifier: String?
    public var bridgeVersion: String?

    // Pump identity
    public var pumpSerial: String?
    public var pumpFirmware: String?
    public var isSimulated = false

    public var isOnboarded = false
    public var insulinTypeRaw: Int?

    // Settings
    public var basalSchedule: InsightBasalSchedule?
    /// The schedule on the pump equals `basalSchedule` (verified by the bridge's read-back).
    public var basalScheduleSynced = false
    /// User/Loop configured limits (the pump's own limits are in `limits`).
    public var maxBolus: Double?
    public var maxBasal: Double?
    public var limits = PumpLimitsState()

    // Last known pump status
    public var reservoirUnits: Double?
    public var batteryPercent: Double?
    public var operatingMode: PumpOperatingMode = .unknown
    public var suspendedSince: Date?
    /// When we last changed the operating mode ourselves (older status reads must not undo it).
    public var modeChangedAt: Date?
    public var pumpLink: PumpLinkState = .unknown
    /// When we last received a status from the bridge.
    public var lastStatusDate: Date?
    /// When the bridge itself last read the pump.
    public var lastPumpReadDate: Date?
    public var lastBridgeContact: Date?
    /// Scheduled basal rate the pump reported (without any TBR).
    public var bridgeBasalRate: Double?
    /// When `bridgeBasalRate` was read (the cross-check compares against the schedule at that time).
    public var bridgeBasalReadAt: Date?
    /// Consecutive fresh status reads whose basal rate disagreed with the local schedule.
    public var basalMismatchCount = 0
    public var basalMismatchReadAt: Date?
    /// First time an unreadable history event was seen (it is skipped after a while).
    public var unreadableSince: Date?
    /// Sequence numbers that were skipped because they stayed unreadable.
    public var skippedHistorySequences: [Int] = []
    public var pumpTimeDriftSeconds: Double?
    public var lastTimeSync: Date?
    public var pumpTimeZoneOffsetSeconds: Int?

    // Dose bookkeeping
    /// TBRs not yet finalized from the pump history (at most one is running).
    public var tempBasals: [ActiveTempBasal] = []
    /// Doses finalized locally whose history event may still arrive (see `FinalizedLocalDose`).
    public var finalizedLocal: [FinalizedLocalDose] = []
    /// Bolus ids that are fully accounted for; a status listing one of them again is not a new bolus.
    public var finalizedBolusIds: [Int] = []
    /// Basal schedules that were active, newest last (for late history events).
    public var scheduleRevisions: [ScheduleRevision] = []
    /// A history event could not be read: the sequence is not advanced past it and the user was told.
    public var unreadableHistoryAlertIssued = false
    public var bolus: UnfinalizedBolus?
    /// The schedule the user/Loop last asked for (may differ from `basalSchedule` after a failed sync).
    public var desiredBasalSchedule: InsightBasalSchedule?
    public var pendingCommand: PendingCommand?
    public var lastHistorySequence: Int?
    public var lastHistoryRead: Date?

    // Alerts
    public var activeAlerts: [PumpAlertRecord] = []
    public var activePumpAlert: BridgeAlert?
    public var disconnectAlertIssued = false
    /// Signature of the non-hourly profile Trio asked for that was converted to hourly rates for the pump
    /// (nil: the pump profile is exactly what was asked for). Optional so older persisted states still decode.
    public var simplifiedProfileSource: String?
    /// A profile write ended without a clean answer (uncertain / read-back failed): worth writing again by itself.
    public var profileWriteFailed: Bool?
    /// Why the last dosing command was refused (shown to the user until a command is accepted again).
    public var loopBlockedReason: String?
    public var loopBlockedAlertAt: Date?

    public init() {}

    public init(bridgeId: String, bridgeName: String?, peripheralIdentifier: String?) {
        self.bridgeId = bridgeId
        self.bridgeName = bridgeName
        self.peripheralIdentifier = peripheralIdentifier
    }

    // MARK: derived

    public var insulinType: InsulinType? {
        get { insulinTypeRaw.flatMap { InsulinType(rawValue: $0) } }
        set { insulinTypeRaw = newValue?.rawValue }
    }

    /// The schedule that was in force at `date` (falls back to the current one).
    public func schedule(at date: Date) -> InsightBasalSchedule? {
        scheduleRevisions.last(where: { $0.effectiveFrom <= date })?.schedule ?? basalSchedule
    }

    public var isDeliveryUncertain: Bool { pendingCommand?.isUncertain == true }

    public func runningTempBasal(at now: Date = Date()) -> ActiveTempBasal? {
        tempBasals.last { $0.isRunning(at: now) }
    }

    public var isSuspended: Bool { operatingMode == .stopped || operatingMode == .paused }

    /// The lowest known maximum bolus.
    public var effectiveMaxBolus: Double {
        [maxBolus, limits.maxBolus, InsightPumpSpec.maxBolusAbsolute].compactMap { $0 }.min() ?? InsightPumpSpec.maxBolusAbsolute
    }

    public var effectiveBolusStep: Double { limits.bolusStep ?? InsightPumpSpec.defaultBolusStep }

    public var pumpTimeZone: TimeZone {
        pumpTimeZoneOffsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? TimeZone.current
    }

    public func isStatusStale(now: Date = Date()) -> Bool {
        // The *older* of "when the bridge read the pump" and "when we heard from the bridge" decides, and a
        // timestamp from the future (broken clock) counts as stale, never as fresh.
        guard let date = [lastPumpReadDate, lastStatusDate].compactMap({ $0 }).min() else { return true }
        let age = now.timeIntervalSince(date)
        return age < -BridgeStatus.maxClockSkew || age > BridgeProtocol.staleStatusAge
    }

    // MARK: RawRepresentable

    public init?(rawValue: RawValue) {
        guard let version = rawValue["version"] as? Int, version <= Self.currentVersion,
              let json = rawValue["json"] as? Data,
              var decoded = try? JSONDecoder().decode(InsightPumpManagerState.self, from: json)
        else { return nil }
        // A command that was in flight when the app died has an unknown outcome.
        if decoded.pendingCommand != nil { decoded.pendingCommand?.isUncertain = true }
        self = decoded
    }

    /// The last blob that was encoded successfully (kept so a failing encode can never wipe the persisted state).
    private static let lastGoodBlob = Locked(Data())

    public var rawValue: RawValue {
        var blob: Data
        do {
            blob = try JSONEncoder().encode(self)
            Self.lastGoodBlob.value = blob
        } catch {
            // Never persist an empty blob: that would lose the dose records. Keep the last good state.
            InsightLog(category: "State")
                .error("STATE ENCODING FAILED, keeping the last good state: \(String(describing: error))")
            blob = Self.lastGoodBlob.value
        }
        var raw: RawValue = ["version": Self.currentVersion, "json": blob]
        // Mirrors used by the HUD's raw state (read without decoding the whole blob)
        raw["reservoirLevel"] = reservoirUnits
        raw["lastStatusDate"] = lastStatusDate
        return raw
    }
}

extension InsightPumpManagerState: CustomDebugStringConvertible {
    public var debugDescription: String {
        [
            "## InsightPumpManagerState",
            "bridge: \(bridgeName ?? "-") (\(bridgeId ?? "-"))",
            "serial: \(pumpSerial ?? "-") fw: \(pumpFirmware ?? "-") simulated: \(isSimulated)",
            "onboarded: \(isOnboarded)",
            "mode: \(operatingMode.rawValue) link: \(pumpLink.rawValue)",
            "reservoir: \(reservoirUnits.map { String($0) } ?? "-") battery: \(batteryPercent.map { String($0) } ?? "-")",
            "lastStatus: \(lastStatusDate.map { String(describing: $0) } ?? "-")",
            "lastHistorySequence: \(lastHistorySequence.map { String($0) } ?? "-")",
            "tbr: \(tempBasals.map { "\($0.percent)% x \($0.durationMinutes)min" }.joined(separator: ","))",
            "bolus: \(bolus.map { "\($0.units)U \($0.phase.rawValue)" } ?? "none")",
            "pending: \(pendingCommand.map { "\($0.kind.rawValue) uncertain=\($0.isUncertain)" } ?? "none")",
            "scheduleSynced: \(basalScheduleSynced)"
        ].joined(separator: "\n")
    }
}
