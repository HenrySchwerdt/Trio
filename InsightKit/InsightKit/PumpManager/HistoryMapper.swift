import Foundation
import LoopKit

struct HistoryMappingContext {
    var serial: String
    var schedule: InsightBasalSchedule?
    var timeZone: TimeZone
    var insulinType: InsulinType?
    var bolus: UnfinalizedBolus?
    var tempBasals: [ActiveTempBasal] = []
    /// Basal schedules that were active, newest last: late events are costed with the schedule of their time.
    var scheduleRevisions: [ScheduleRevision] = []
    /// Doses already finalized locally: a late history event for one of them reuses its sync identifier.
    var finalizedLocal: [FinalizedLocalDose] = []

    func schedule(at date: Date) -> InsightBasalSchedule? {
        scheduleRevisions.last(where: { $0.effectiveFrom <= date })?.schedule ?? schedule
    }
}

struct HistoryMappingResult {
    var events: [NewPumpEvent] = []
    /// A `bolusDelivered` event that belongs to `context.bolus`.
    var matchedBolusEvent: HistoryEvent?
    /// Start dates of `context.tempBasals` entries that a `tbrEnd` event finalized.
    var matchedTempBasalStarts: [Date] = []
    /// Keys of `context.finalizedLocal` entries that a history event confirmed.
    var matchedFinalizedKeys: [String] = []
    var highestSequence: Int?
    /// Sequence numbers of events whose content was implausible/unreadable (history must not move past them).
    var unreadableSequences: [Int] = []
    /// Bolus ids seen as finalized by the history.
    var finalizedBolusIds: [Int] = []
}

enum HistoryMapper {
    /// A bolus larger than this cannot be real on this pump; such a value is treated as unreadable.
    static let maxPlausibleBolus = 50.0

    /// Drops everything already processed and duplicates, ordered by sequence number.
    static func newEvents(_ events: [HistoryEvent], after lastSequence: Int?) -> [HistoryEvent] {
        var seen = Set<Int>()
        return events
            .filter { event in
                if let lastSequence, event.seq <= lastSequence { return false }
                return seen.insert(event.seq).inserted
            }
            .sorted { $0.seq < $1.seq }
    }

    static func raw(_ event: HistoryEvent, serial: String) -> Data {
        Data("insight:\(serial):\(event.seq):\(event.typeName):\(event.time.epochSeconds)".utf8)
    }

    static func matches(_ bolus: UnfinalizedBolus, _ event: HistoryEvent) -> Bool {
        guard event.kind == .bolusDelivered || event.kind == .bolusProgrammed else { return false }
        if let id = bolus.bolusId, let eventId = event.int("bolusId") {
            return eventId == id
        }
        let programmed = event.number("programmed") ?? event.number("amount")
        guard let programmed, abs(programmed - bolus.units) < 0.005 else { return false }
        let start = event.date("start") ?? event.time
        return start >= bolus.startDate.addingTimeInterval(-120) && start <= bolus.startDate.addingTimeInterval(600)
    }

    static func matches(_ local: FinalizedLocalDose, bolusEvent event: HistoryEvent) -> Bool {
        guard local.kind == .bolus else { return false }
        if let id = local.bolusId, let eventId = event.int("bolusId") { return id == eventId }
        guard let units = local.units, let programmed = event.number("programmed") ?? event.number("amount"),
              abs(programmed - units) < 0.005 else { return false }
        let start = event.date("start") ?? event.time
        return start >= local.start.addingTimeInterval(-120) && start <= local.start.addingTimeInterval(600)
    }

    static func map(_ events: [HistoryEvent], context: HistoryMappingContext) -> HistoryMappingResult {
        var result = HistoryMappingResult()
        let offset = context.timeZone.secondsFromGMT()

        for event in events {
            result.highestSequence = max(result.highestSequence ?? event.seq, event.seq)
            let raw = raw(event, serial: context.serial)

            switch event.kind {
            case .bolusProgrammed:
                // The delivered event carries the dose; the programmed marker would only duplicate it.
                continue

            case .bolusDelivered:
                mapDeliveredBolus(event, raw: raw, context: context, result: &result)

            case .tbrStart:
                let title = event.int("percent")
                    .map { String(format: LocalizedString("Temp basal started (%d%%)", comment: "Pump event"), $0) }
                    ?? LocalizedString("Temp basal started", comment: "Pump event")
                result.events.append(info(event, raw: raw, title: title))

            case .tbrEnd:
                mapTempBasalEnd(event, raw: raw, context: context, offset: offset, result: &result)

            case .operatingModeChanged:
                let newMode = event.string("newMode") ?? ""
                let oldMode = event.string("oldMode") ?? ""
                if newMode == "stopped" || newMode == "paused" {
                    let dose = DoseEntry(suspendDate: event.time)
                    result.events
                        .append(NewPumpEvent(
                            date: event.time,
                            dose: dose,
                            raw: raw,
                            title: LocalizedString("Suspend", comment: "Pump event"),
                            type: .suspend
                        ))
                } else if newMode == "started", oldMode != "started" {
                    let dose = DoseEntry(resumeDate: event.time, insulinType: context.insulinType)
                    result.events
                        .append(NewPumpEvent(
                            date: event.time,
                            dose: dose,
                            raw: raw,
                            title: LocalizedString("Resume", comment: "Pump event"),
                            type: .resume
                        ))
                } else {
                    result.events
                        .append(info(event, raw: raw, title: LocalizedString("Operating mode changed", comment: "Pump event")))
                }

            case .cartridgeRemoved:
                result.events.append(NewPumpEvent(
                    date: event.time,
                    dose: nil,
                    raw: raw,
                    title: LocalizedString("Cartridge removed", comment: "Pump event"),
                    type: .rewind
                ))

            case .cartridgeInserted:
                result.events.append(info(event, raw: raw, title: LocalizedString("Cartridge inserted", comment: "Pump event")))

            case .tubeFilled:
                result.events
                    .append(NewPumpEvent(
                        date: event.time,
                        dose: nil,
                        raw: raw,
                        title: LocalizedString("Tube filled", comment: "Pump event"),
                        type: .prime
                    ))

            case .cannulaFilled:
                result.events.append(NewPumpEvent(
                    date: event.time,
                    dose: nil,
                    raw: raw,
                    title: LocalizedString("Cannula filled", comment: "Pump event"),
                    type: .prime
                ))

            case .alert:
                let type = event.string("alertType") ?? "unknown"
                let category = BridgeAlertCategory(rawValue: event.string("category") ?? "") ?? .unknown
                let alert = BridgeAlert(alertId: event.int("alertId") ?? 0, alertType: type, category: category)
                let details = InsightAlertCatalog.info(for: alert)
                result.events.append(NewPumpEvent(
                    date: event.time, dose: nil, raw: raw, title: details.title, type: .alarm,
                    alarmType: alarmType(for: details, rawType: type)
                ))

            case .basalRateChanged:
                result.events.append(info(event, raw: raw, title: LocalizedString("Basal rate changed", comment: "Pump event")))
            case .totalDailyDose:
                result.events.append(info(event, raw: raw, title: LocalizedString("Total daily dose", comment: "Pump event")))
            case .dateTimeChanged:
                result.events.append(info(event, raw: raw, title: LocalizedString("Pump time changed", comment: "Pump event")))
            case .other:
                result.events.append(info(event, raw: raw, title: event.string("raw") ?? event.typeName))
            }
        }
        return result
    }

    // MARK: bolus

    private static func plausible(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maxPlausibleBolus else { return nil }
        return value
    }

    private static func mapDeliveredBolus(
        _ event: HistoryEvent, raw: Data, context: HistoryMappingContext, result: inout HistoryMappingResult
    ) {
        let programmed = plausible(event.number("programmed") ?? event.number("amount"))
        let delivered = plausible(event.number("delivered"))
        let bolusId = event.int("bolusId")

        let ours = context.bolus.flatMap { matches($0, event) ? $0 : nil }
        let local = ours == nil ? context.finalizedLocal.first { matches($0, bolusEvent: event) } : nil
        let key = ours
            .map {
                $0.bolusId == nil && bolusId != nil ? "insight:\(context.serial):bolus:\(bolusId!)" : $0
                    .syncKey(serial: context.serial) }
            ?? local?.key
            ?? bolusId.map { "insight:\(context.serial):bolus:\($0)" }
        let rawKey = key.map { Data($0.utf8) } ?? raw

        // What counts as delivered. When the numbers do not add up, take the larger (more insulin on board).
        var isReadable = true
        var counted: Double
        if let programmed, let delivered, delivered <= programmed + 0.01 {
            counted = delivered
        } else {
            isReadable = false
            counted = max(programmed ?? 0, delivered ?? 0)
        }
        guard counted > 0 || (programmed != nil && delivered != nil) else {
            // nothing usable at all: remember that the history cannot be trusted past here
            result.unreadableSequences.append(event.seq)
            result.events.append(info(event, raw: raw, title: LocalizedString("Bolus (unreadable)", comment: "Pump event")))
            return
        }
        if !isReadable { result.unreadableSequences.append(event.seq) }

        if ours != nil { result.matchedBolusEvent = event }
        if let local { result.matchedFinalizedKeys.append(local.key) }
        if let id = bolusId ?? ours?.bolusId ?? local?.bolusId { result.finalizedBolusIds.append(id) }

        let start = event.date("start") ?? event.time
        let end = max(event.date("end") ?? event.time, start)
        let dose = DoseEntry(
            type: .bolus, startDate: start, endDate: end, value: max(programmed ?? counted, counted), unit: .units,
            decisionId: ours?.decisionId, deliveredUnits: counted,
            insulinType: context.insulinType, automatic: ours?.automatic,
            isMutable: false, wasProgrammedByPumpUI: ours == nil && local == nil
        )
        result.events
            .append(NewPumpEvent(
                date: start,
                dose: dose,
                raw: rawKey,
                title: LocalizedString("Bolus", comment: "Pump event"),
                type: .bolus
            ))
    }

    /// An event that could not even be decoded: if it was a bolus with a readable programmed amount it is
    /// counted as delivered in full (never lose insulin on board).
    static func conservativeEvent(
        for unreadable: UnreadableHistoryEvent,
        context: HistoryMappingContext,
        now: Date
    ) -> NewPumpEvent? {
        guard unreadable.isBolus, let programmed = plausible(unreadable.programmed), programmed > 0 else { return nil }
        let start = unreadable.time ?? now
        let key = unreadable.seq.map { "insight:\(context.serial):unreadable:\($0)" }
            ?? "insight:\(context.serial):unreadable-bolus:\(start.epochSeconds):\(programmed)"
        let dose = DoseEntry(
            type: .bolus, startDate: start,
            endDate: start.addingTimeInterval(InsightPumpManager.deliveryDuration(units: programmed)),
            value: programmed, unit: .units, decisionId: nil, deliveredUnits: programmed,
            insulinType: context.insulinType, isMutable: false, wasProgrammedByPumpUI: true
        )
        return NewPumpEvent(
            date: start,
            dose: dose,
            raw: Data(key.utf8),
            title: LocalizedString("Bolus (unreadable)", comment: "Pump event"),
            type: .bolus
        )
    }

    // MARK: temp basal

    private static func mapTempBasalEnd(
        _ event: HistoryEvent, raw: Data, context: HistoryMappingContext, offset: Int, result: inout HistoryMappingResult
    ) {
        let endedTitle = LocalizedString("Temp basal ended", comment: "Pump event")
        guard let percent = event.int("percent"), let minutes = event.int("duration"),
              (0 ... InsightPumpSpec.tbrMaxPercent).contains(percent), (0 ... InsightPumpSpec.tbrMaxMinutes).contains(minutes)
        else {
            result.unreadableSequences.append(event.seq)
            result.events.append(info(event, raw: raw, title: endedTitle))
            return
        }
        guard minutes > 0 else {
            result.events.append(info(event, raw: raw, title: endedTitle))
            return
        }
        let end = event.time
        let start = end.addingTimeInterval(-TimeInterval(minutes) * 60)

        let ours = context.tempBasals.first { abs($0.start.timeIntervalSince(start)) < 180 && $0.percent == percent }
        let local = ours == nil
            ? context.finalizedLocal
            .first { $0.kind == .tempBasal && $0.percent == percent && abs($0.start.timeIntervalSince(start)) < 180 }
            : nil
        if let ours { result.matchedTempBasalStarts.append(ours.start) }
        if let local { result.matchedFinalizedKeys.append(local.key) }

        // The schedule of that time (snapshot taken when we set it, otherwise the one that was active then).
        let schedule = ours?.schedule ?? context.schedule(at: start)
        guard schedule != nil || ours != nil else {
            result.events.append(info(event, raw: raw, title: endedTitle))
            return
        }
        let accounting = TempBasalAccounting.account(
            percent: percent, start: start, end: end, schedule: schedule,
            utcOffset: ours?.utcOffsetSeconds ?? offset, fallbackRate: ours?.scheduledRate ?? 0
        )
        let key = ours?.syncKey(serial: context.serial) ?? local?.key
        let dose = DoseEntry(
            type: .tempBasal, startDate: start, endDate: end, value: accounting.averageRate, unit: .unitsPerHour,
            decisionId: ours?.decisionId, deliveredUnits: accounting.deliveredUnits,
            scheduledBasalRate: LoopQuantity(unit: DoseEntry.unitsPerHour, doubleValue: accounting.averageScheduledRate),
            insulinType: context.insulinType, automatic: ours?.automatic,
            isMutable: false, wasProgrammedByPumpUI: ours == nil && local == nil
        )
        result.events.append(NewPumpEvent(
            date: start, dose: dose, raw: key.map { Data($0.utf8) } ?? raw,
            title: LocalizedString("Temp Basal", comment: "Pump event"), type: .tempBasal
        ))
    }

    private static func info(_ event: HistoryEvent, raw: Data, title: String) -> NewPumpEvent {
        NewPumpEvent(date: event.time, dose: nil, raw: raw, title: title)
    }

    static func alarmType(for info: InsightAlertInfo, rawType: String) -> PumpAlarmType {
        switch (info.severity, info.code) {
        case (.warning, 31): return .lowInsulin
        case (.warning, 32): return .lowPower
        default: return .other(rawType)
        }
    }
}

// MARK: - DoseEntry builders for in-flight doses

enum DoseFactory {
    static func bolusDose(_ bolus: UnfinalizedBolus, mutable: Bool, insulinType: InsulinType?) -> DoseEntry {
        DoseEntry(
            type: .bolus, startDate: bolus.startDate, endDate: bolus.expectedEnd, value: bolus.units, unit: .units,
            decisionId: bolus.decisionId, deliveredUnits: mutable ? nil : bolus.deliveredUnits,
            insulinType: insulinType, automatic: bolus.automatic, isMutable: mutable,
            wasProgrammedByPumpUI: bolus.programmedOnPump
        )
    }

    /// Costed hour by hour against the schedule snapshot taken when the TBR was set.
    static func tempBasalDose(
        _ tbr: ActiveTempBasal,
        mutable: Bool,
        insulinType: InsulinType?,
        endDate: Date? = nil
    ) -> DoseEntry {
        let end = endDate ?? tbr.end
        let accounting = tbr.accounting(until: end)
        return DoseEntry(
            type: .tempBasal, startDate: tbr.start, endDate: end, value: accounting.averageRate, unit: .unitsPerHour,
            decisionId: tbr.decisionId, deliveredUnits: mutable ? nil : accounting.deliveredUnits,
            scheduledBasalRate: LoopQuantity(unit: DoseEntry.unitsPerHour, doubleValue: accounting.averageScheduledRate),
            insulinType: insulinType, automatic: tbr.automatic, isMutable: mutable
        )
    }

    static func event(for dose: DoseEntry, key: String, title: String) -> NewPumpEvent {
        NewPumpEvent(date: dose.startDate, dose: dose, raw: Data(key.utf8), title: title)
    }
}
