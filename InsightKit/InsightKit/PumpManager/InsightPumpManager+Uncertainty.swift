import Foundation
import LoopKit

enum PendingResolution: Equatable {
    case delivered
    case notDelivered
    case undecided
}

/// What a `getRequestOutcome` answer means for an uncertain command.
enum OutcomeVerdict: Equatable {
    case delivered
    case notDelivered
    /// The bridge is still working on it: ask again later, never decide.
    case inProgress
    /// The bridge cannot tell: fall back to the status + history evidence.
    case evidence
}

/// Decides what happened to a command whose outcome was unknown. Pure so it can be tested exhaustively.
/// Only *positive evidence* settles a "not delivered": a status read well after the command was sent, with the
/// pump connected, readable fields and a complete history.
enum UncertaintyResolver {
    static func verdict(for outcome: RequestOutcomeResult) -> OutcomeVerdict {
        switch outcome.state {
        case .succeeded: return .delivered
        case .failed: return outcome.error?.uncertain == true ? .evidence : .notDelivered
        case .inProgress: return .inProgress
        case .uncertain,
             .unknown: return .evidence
        }
    }

    static func decide(
        command: PendingCommand,
        status: BridgeStatus,
        history: [HistoryEvent],
        historyComplete: Bool,
        now: Date = Date()
    ) -> PendingResolution {
        // A read time from the future (broken bridge clock) proves nothing: it is neither fresh nor settled.
        let readAt = status.timestamp.flatMap { $0 > now.addingTimeInterval(BridgeStatus.maxClockSkew) ? nil : $0 }
        // positive evidence ("it happened") only needs a read after the command ...
        let statusIsFresh = readAt.map { $0 > command.sentDate } ?? false
        // ... "it did not happen" needs a read that had time to see the effect, from a connected pump
        let settled = readAt.map { $0 > command.sentDate.addingTimeInterval(BridgeProtocol.notDeliveredSettleTime) } ?? false
        let canProveAbsence = settled && status.pumpLink == .connected && historyComplete

        let sinceBaseline = history.filter { event in
            if let base = command.baselineSequence, event.seq <= base { return false }
            return event.time >= command.sentDate.addingTimeInterval(-60)
        }

        switch command.kind {
        case .bolus:
            let units = command.units ?? -1
            let seen = sinceBaseline.contains { event in
                guard event.kind == .bolusDelivered || event.kind == .bolusProgrammed else { return false }
                let amount = event.number("programmed") ?? event.number("amount") ?? -1
                return abs(amount - units) < 0.005
            }
            if seen { return .delivered }
            if status.bolusesAreUnreadable { return .undecided }
            if statusIsFresh, status.boluses.contains(where: { abs($0.amount - units) < 0.005 }) { return .delivered }
            if canProveAbsence, status.boluses.isEmpty { return .notDelivered }
            return .undecided

        case .setTBR:
            let percent = command.percent ?? -1
            let seen = sinceBaseline.contains { $0.kind == .tbrStart && $0.int("percent") == percent }
            if seen { return .delivered }
            if status.tbrIsUnreadable { return .undecided }
            if statusIsFresh, let tbr = status.tbr, tbr.percent == percent { return .delivered }
            return canProveAbsence ? .notDelivered : .undecided

        case .cancelTBR:
            if status.tbrIsUnreadable { return .undecided }
            if statusIsFresh, status.tbr == nil { return .delivered }
            return status.tbr != nil && settled && status.pumpLink == .connected ? .notDelivered : .undecided

        case .suspend:
            guard statusIsFresh, status.operatingMode != .unknown else { return .undecided }
            if !status.operatingMode.isDelivering { return .delivered }
            return settled && status.pumpLink == .connected ? .notDelivered : .undecided

        case .resume:
            guard statusIsFresh, status.operatingMode != .unknown else { return .undecided }
            if status.operatingMode.isDelivering { return .delivered }
            return settled && status.pumpLink == .connected ? .notDelivered : .undecided
        }
    }
}

public enum UncertaintyOutcome: Equatable {
    case none
    case delivered
    case notDelivered
    case undecided
    case unreachable
}

extension InsightPumpManager {
    // MARK: marking

    func markUncertain(requestId: String, error _: BridgeError) {
        log.warning("command outcome uncertain")
        mutate { st in
            if st.pendingCommand?.requestId == requestId { st.pendingCommand?.isUncertain = true }
        }
        reportCurrentDoses(history: [], highest: nil)
        notifyStateDidChange()
        scheduleUncertaintyRetry(after: 5)
    }

    func scheduleUncertaintyRetry(after interval: TimeInterval) {
        uncertaintyRetry?.cancel()
        uncertaintyRetry = scheduler.schedule(after: interval) { [weak self] in
            guard let self else { return }
            self.uncertaintyRetry = nil
            self.resolvePendingCommandIfNeeded(reason: "retry")
        }
    }

    // MARK: resolving (read only: never sends a dosing command)

    func resolvePendingCommandIfNeeded(reason: String, completion: ((UncertaintyOutcome) -> Void)? = nil) {
        guard let pending = state.pendingCommand, pending.isUncertain else {
            completion?(.none)
            return
        }
        log.info("resolving uncertain command (\(reason))")
        commandQueue.enqueue("resolve") { done in
            guard let command = self.state.pendingCommand, command.isUncertain, command.requestId == pending.requestId else {
                completion?(.none)
                done()
                return
            }
            // 1. The bridge's own record of the request is authoritative when it has a final answer.
            self.client.getRequestOutcome(requestId: command.requestId) { result in
                self.queue.async {
                    switch result {
                    case let .failure(error):
                        if case .remote = error {
                            // The bridge answered with an error (e.g. an older bridge): use the evidence path.
                            self.resolveFromEvidence(command: command, completion: completion, done: done)
                        } else {
                            self.scheduleUncertaintyRetry(after: 60)
                            completion?(.unreachable)
                            done()
                        }
                    case let .success(outcome):
                        switch UncertaintyResolver.verdict(for: outcome) {
                        case .delivered:
                            self.applyOutcome(command: command, delivered: true, outcome: outcome, completion: completion)
                            done()
                        case .notDelivered:
                            self.applyOutcome(command: command, delivered: false, outcome: outcome, completion: completion)
                            done()
                        case .inProgress:
                            // Ask again later (the query, never the command).
                            let delays = BridgeProtocol.outcomeBackoff
                            let delay = delays[min(self.outcomeAttempts, delays.count - 1)]
                            self.outcomeAttempts += 1
                            self.scheduleUncertaintyRetry(after: delay)
                            self.notifyStateDidChange()
                            completion?(.undecided)
                            done()
                        case .evidence:
                            self.resolveFromEvidence(command: command, completion: completion, done: done)
                        }
                    }
                }
            }
        }
    }

    /// 2. No final answer from the bridge: compare status and history with the command.
    private func resolveFromEvidence(
        command: PendingCommand,
        completion: ((UncertaintyOutcome) -> Void)?,
        done: @escaping () -> Void
    ) {
        client.getStatus { result in
            self.queue.async {
                switch result {
                case .failure:
                    self.scheduleUncertaintyRetry(after: 60)
                    completion?(.unreachable)
                    done()
                case let .success(received):
                    let status = received.sanitized(now: self.clock())
                    self.applyStatus(status)
                    self.syncHistoryForResolution { complete in
                        self.queue.async {
                            self.finishResolution(
                                command: command,
                                status: status,
                                historyComplete: complete,
                                completion: completion
                            )
                            done()
                        }
                    }
                }
            }
        }
    }

    /// The bridge reported a final outcome for the request.
    private func applyOutcome(
        command: PendingCommand,
        delivered: Bool,
        outcome: RequestOutcomeResult,
        completion: ((UncertaintyOutcome) -> Void)?
    ) {
        outcomeAttempts = 0
        if delivered {
            adoptDelivered(command, status: lastStatus, outcomeResult: outcome.result, outcomeDate: outcome.completedAt)
        } else {
            log.info("the bridge says the command failed")
        }
        mutate { $0.pendingCommand = nil }
        reportCurrentDoses(history: [], highest: nil)
        notifyStateDidChange()
        completion?(delivered ? .delivered : .notDelivered)
        refreshAll(reason: "uncertain command resolved by the bridge")
    }

    private func syncHistoryForResolution(_ completion: @escaping (Bool) -> Void) {
        let since = state.lastHistorySequence
        historyWasComplete = false
        client.readHistory(since: since, max: BridgeProtocol.historyPageSize) { result in
            self.queue.async {
                switch result {
                case .failure:
                    completion(false)
                case let .success(page):
                    self.process(
                        history: page.events,
                        unreadable: page.unreadable,
                        pageLast: page.lastSequence,
                        complete: !page.more
                    ) {
                        completion(!page.more)
                    }
                }
            }
        }
    }

    private func finishResolution(
        command: PendingCommand, status: BridgeStatus, historyComplete: Bool,
        completion: ((UncertaintyOutcome) -> Void)?
    ) {
        var outcome = UncertaintyResolver.decide(
            command: command, status: status, history: lastHistoryEvents, historyComplete: historyComplete, now: clock()
        )
        if matchedPendingBolus, command.kind == .bolus { outcome = .delivered }

        switch outcome {
        case .undecided:
            scheduleUncertaintyRetry(after: 60)
            notifyStateDidChange()
            completion?(.undecided)
            return
        case .delivered:
            adoptDelivered(command, status: status, outcomeResult: nil, outcomeDate: nil)
        case .notDelivered:
            log.info("uncertain command was not executed")
        }

        outcomeAttempts = 0
        mutate { $0.pendingCommand = nil }
        reportCurrentDoses(history: [], highest: nil)
        notifyStateDidChange()
        completion?(outcome == .delivered ? .delivered : .notDelivered)
    }

    /// The command did run: make our records match.
    private func adoptDelivered(
        _ command: PendingCommand,
        status: BridgeStatus?,
        outcomeResult: BridgeValue?,
        outcomeDate: Date?
    ) {
        let now = clock()
        let tz = state.pumpTimeZone
        mutate { st in
            switch command.kind {
            case .bolus:
                guard let units = command.units else { return }
                let reportedId = outcomeResult?["bolusId"]?.intValue
                if var existing = st.bolus {
                    // The running bolus was already adopted from the status as "programmed on the pump".
                    if existing.programmedOnPump, abs(existing.units - units) < 0.005 {
                        existing.requestId = command.requestId
                        existing.decisionId = command.decisionId
                        existing.automatic = command.automatic
                        existing.insulinType = command.insulinType
                        existing.startDate = command.sentDate
                        existing.programmedOnPump = false
                        st.bolus = existing
                    }
                    return
                }
                if let id = reportedId, st.finalizedBolusIds.contains(id) { return }
                if let active = status?.boluses
                    .first(where: { abs($0.amount - units) < 0.005 && !st.finalizedBolusIds.contains($0.bolusId) })
                {
                    st.bolus = UnfinalizedBolus(
                        requestId: command.requestId, units: units, startDate: command.sentDate, bolusId: active.bolusId,
                        decisionId: command.decisionId, automatic: command.automatic, insulinType: command.insulinType,
                        deliveredUnits: max(units - active.remaining, 0), phase: .inProgress, endDate: nil,
                        programmedOnPump: false, acceptedAt: now
                    )
                } else if let id = reportedId, !matchedPendingBolus {
                    // The bridge confirmed the bolus and its id: track it until status/history finalize it.
                    st.bolus = UnfinalizedBolus(
                        requestId: command.requestId, units: units, startDate: command.sentDate, bolusId: id,
                        decisionId: command.decisionId, automatic: command.automatic, insulinType: command.insulinType,
                        deliveredUnits: 0, phase: .inProgress, endDate: nil, programmedOnPump: false,
                        acceptedAt: outcomeDate ?? now
                    )
                }
            case .setTBR:
                if let i = st.tempBasals.lastIndex(where: { $0.endedAt == nil && $0.percent == command.percent }) {
                    st.tempBasals[i].decisionId = command.decisionId
                    st.tempBasals[i].automatic = command.automatic
                } else if let percent = outcomeResult?["percent"]?.intValue ?? command.percent,
                          let minutes = outcomeResult?["duration"]?.intValue ?? command.durationMinutes,
                          (0 ... InsightPumpSpec.tbrMaxPercent).contains(percent),
                          (1 ... InsightPumpSpec.tbrMaxMinutes).contains(minutes)
                {
                    let schedule = st.schedule(at: command.sentDate)
                    let scheduled = command.scheduledRate ?? schedule?.rate(at: command.sentDate, in: tz) ?? 0
                    st.tempBasals.append(ActiveTempBasal(
                        percent: percent, durationMinutes: minutes, start: command.sentDate, scheduledRate: scheduled,
                        effectiveRate: TempBasalConverter.effectiveRate(percent: percent, scheduledRate: scheduled),
                        decisionId: command.decisionId, automatic: command.automatic, endedAt: nil,
                        schedule: schedule,
                        utcOffsetSeconds: st.pumpTimeZoneOffsetSeconds ?? tz.secondsFromGMT(for: command.sentDate)
                    ))
                }
            case .suspend:
                st.operatingMode = .stopped
                st.suspendedSince = command.sentDate
                st.modeChangedAt = command.sentDate
            case .resume:
                st.operatingMode = .started
                st.suspendedSince = nil
                st.modeChangedAt = command.sentDate
            case .cancelTBR:
                for i in st.tempBasals.indices where st.tempBasals[i].endedAt == nil {
                    st.tempBasals[i].endedAt = min(command.sentDate, st.tempBasals[i].plannedEnd)
                }
            }
        }
        if command.kind == .bolus, let bolus = state.bolus, bolus.phase == .inProgress {
            doseReporter = InsightDoseProgressReporter(total: bolus.units, delivered: bolus.deliveredUnits)
            armBolusWatch()
        }
    }

    // MARK: user resolution

    /// The user checked the pump: `delivered == true` means the insulin was given.
    public func forceResolvePendingCommand(delivered: Bool, completion: (() -> Void)? = nil) {
        queue.async {
            guard let command = self.state.pendingCommand else { completion?()
                return }
            self.mutate { st in
                if delivered, command.kind == .bolus, st.bolus == nil, let units = command.units {
                    // Count it as given; the history will confirm and replace this record.
                    st.bolus = UnfinalizedBolus(
                        requestId: command.requestId, units: units, startDate: command.sentDate, bolusId: nil,
                        decisionId: command.decisionId, automatic: command.automatic, insulinType: command.insulinType,
                        deliveredUnits: units, phase: .finished,
                        endDate: command.sentDate.addingTimeInterval(InsightPumpManager.deliveryDuration(units: units)),
                        programmedOnPump: false
                    )
                }
                st.pendingCommand = nil
            }
            self.log.info("uncertain command resolved by the user (delivered: \(delivered))")
            self.reportCurrentDoses(history: [], highest: nil)
            self.notifyStateDidChange()
            self.refreshAll(reason: "user resolved uncertainty")
            completion?()
        }
    }

    /// "Check again" in the recovery UI.
    public func checkUncertainCommand(completion: @escaping (UncertaintyOutcome) -> Void) {
        queue.async {
            self.client.ensureStarted()
            self.resolvePendingCommandIfNeeded(reason: "user") { outcome in
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    // MARK: time

    public func syncTime(completion: ((Result<Void, BridgeError>) -> Void)? = nil) {
        queue.async {
            self.commandQueue.enqueue("setDateTime") { done in
                let now = self.clock()
                let offset = TimeZone.current.secondsFromGMT(for: now)
                self.client.setDateTime(utc: now, tzOffsetMinutes: offset / 60) { result in
                    self.queue.async {
                        switch result {
                        case .success:
                            let drift = self.state.pumpTimeDriftSeconds ?? 0
                            self.mutate { st in
                                st.lastTimeSync = now
                                st.pumpTimeZoneOffsetSeconds = offset
                                st.pumpTimeDriftSeconds = 0
                            }
                            if abs(drift) >= 1 {
                                self.pumpDelegate.notify { [weak self] delegate in
                                    guard let self else { return }
                                    delegate?.pumpManager(self, didAdjustPumpClockBy: -drift)
                                }
                            }
                            self.notifyStateDidChange()
                            self.refreshAll(reason: "time synced")
                            completion?(.success(()))
                        case let .failure(error):
                            self.notifyStateDidChange()
                            completion?(.failure(error))
                        }
                        done()
                    }
                }
            }
        }
    }

    var needsTimeSync: Bool {
        let s = state
        let drift = abs(s.pumpTimeDriftSeconds ?? 0)
        let zoneMismatch = s.pumpTimeZoneOffsetSeconds.map { $0 != TimeZone.current.secondsFromGMT() } ?? false
        return drift > 60 || zoneMismatch
    }

    func maybeSyncTimeAutomatically() {
        let s = state
        guard s.isOnboarded, client.sessionState == .ready, s.pendingCommand == nil, s.bolus?.phase != .inProgress else { return }
        let drift = abs(s.pumpTimeDriftSeconds ?? 0)
        let zoneMismatch = s.pumpTimeZoneOffsetSeconds.map { $0 != TimeZone.current.secondsFromGMT() } ?? false
        let recentlySynced = s.lastTimeSync.map { clock().timeIntervalSince($0) < 3600 } ?? false
        guard drift > 300 || zoneMismatch, !recentlySynced else { return }
        log.info("automatic time sync (drift \(drift.clampedInt) s, zone mismatch: \(zoneMismatch))")
        syncTime()
    }

    func handleTimeZoneChange() {
        notifyStateDidChange()
        guard state.isOnboarded else { return }
        mutate { $0.lastTimeSync = nil }
        maybeSyncTimeAutomatically()
    }

    // MARK: alerts

    func reconcileAlert(_ alert: BridgeAlert?) {
        let s = state
        let active = alert.flatMap { $0.isSnoozed ? nil : $0 }
        var toRetract = [PumpAlertRecord]()
        var toIssue: BridgeAlert?
        let activeId = active.map { InsightAlertCatalog.alertIdentifier(for: $0) }

        mutate { st in
            toRetract = st.activeAlerts.filter { $0.loopIdentifier != activeId }
            st.activeAlerts.removeAll { $0.loopIdentifier != activeId }
            if let active, let activeId, !s.activeAlerts.contains(where: { $0.loopIdentifier == activeId }) {
                st.activeAlerts.append(PumpAlertRecord(
                    alertId: active.alertId, alertType: active.alertType, category: active.category.rawValue,
                    loopIdentifier: activeId, issuedAt: self.clock()
                ))
                toIssue = active
            }
            st.activePumpAlert = alert
        }

        if let toIssue {
            let loopAlert = InsightAlertCatalog.loopAlert(for: toIssue)
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.issueAlert(loopAlert) }
            }
        }
        for record in toRetract {
            let id = Alert.Identifier(
                managerIdentifier: InsightAlertCatalog.managerIdentifier,
                alertIdentifier: record.loopIdentifier
            )
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.retractAlert(identifier: id) }
            }
        }
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {
        guard let record = state.activeAlerts.first(where: { $0.loopIdentifier == alertIdentifier }) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandQueue.enqueue("confirmAlert") { done in
                self.client.confirmAlert(alertId: record.alertId, alertType: record.alertType) { result in
                    self.queue.async {
                        switch result {
                        case .success:
                            self.mutate { $0.activeAlerts.removeAll { $0.loopIdentifier == alertIdentifier } }
                            self.notifyStateDidChange()
                            self.refreshAll(reason: "alert confirmed")
                            continuation.resume()
                        case let .failure(error):
                            continuation.resume(throwing: error)
                        }
                        done()
                    }
                }
            }
        }
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}
