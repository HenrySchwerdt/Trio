import Foundation
import LoopKit

extension InsightPumpManager: PumpManager {
    // MARK: onboarding constants

    public static var onboardingMaximumBasalScheduleEntryCount: Int { 24 }
    /// Uniform 0.01 U/h grid up to 5 U/h: onboarding pickers need an evenly spaced grid, and the Insight
    /// switches to 0.1 U/h steps above 5 U/h. Once paired, `supportedBasalRates` offers the full banded grid.
    public static var onboardingSupportedBasalRates: [Double] { InsightPumpSpec.supportedBasalRates.filter { $0 <= 5.0 + 1E-9 } }
    public static var onboardingSupportedBolusVolumes: [Double] { InsightPumpSpec.supportedBolusVolumes }
    public static var onboardingSupportedMaximumBolusVolumes: [Double] { InsightPumpSpec.supportedBolusVolumes }

    public var delegateQueue: DispatchQueue! {
        get { pumpDelegate.queue }
        set { pumpDelegate.queue = newValue }
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get { pumpDelegate.delegate }
        set { pumpDelegate.delegate = newValue }
    }

    public var supportedBasalRates: [Double] { InsightPumpSpec.supportedBasalRates }
    public var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    public var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedMaximumBolusVolumes }
    public var maximumBasalScheduleEntryCount: Int { Self.onboardingMaximumBasalScheduleEntryCount }
    public var minimumBasalScheduleEntryDuration: TimeInterval { .hours(1) }

    /// Rounds *down* to a rate the pump can deliver.
    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour + 1E-9 }) ?? 0
    }

    /// Rounds *down* to a volume the pump can deliver.
    public func roundToSupportedBolusVolume(units: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= units + 1E-9 }) ?? 0
    }

    public var pumpRecordsBasalProfileStartEvents: Bool { false }
    public var pumpReservoirCapacity: Double { InsightPumpSpec.reservoirCapacity }

    public var lastSync: Date? {
        let s = state
        return s.lastHistoryRead ?? s.lastStatusDate
    }

    public var status: PumpManagerStatus { computeStatus() }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func addStateObserver(_ observer: InsightStateObserver, queue: DispatchQueue) {
        stateObservers.insert(observer, queue: queue)
    }

    public func removeStateObserver(_ observer: InsightStateObserver) {
        stateObservers.removeElement(observer)
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        queue.async { self.provideHeartbeat = mustProvideBLEHeartbeat }
    }

    // MARK: data

    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        queue.async {
            self.client.ensureStarted()
            let s = self.state
            guard s.isOnboarded else {
                completion?(self.lastSync)
                return
            }
            let fresh = self.lastStatusReceived.map { self.clock().timeIntervalSince($0) < 60 } ?? false
            let quiet = s.bolus == nil && s.pendingCommand == nil
            if fresh, quiet, self.client.sessionState == .ready {
                completion?(self.lastSync)
                return
            }
            self.refreshAll(reason: "ensureCurrentPumpData") { _ in
                completion?(self.lastSync)
            }
            self.resolvePendingCommandIfNeeded(reason: "ensureCurrentPumpData")
        }
    }

    // MARK: bolus

    public func createBolusProgressReporter(reportingOn _: DispatchQueue) -> DoseProgressReporter? {
        doseReporter
    }

    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        Self.deliveryDuration(units: units)
    }

    public func enactBolus(
        decisionId: UUID?, units: Double, activationType: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        queue.async {
            let s = self.state
            if let error = self.dosingPrecondition(s) { completion(error)
                return }
            guard self.transient.value.bolus == nil, s.bolus?.phase != .inProgress else {
                completion(.deviceState(InsightPumpManagerError.bolusInProgress))
                return
            }
            do {
                try BolusValidator.validate(
                    units: units, maxBolus: s.effectiveMaxBolus,
                    step: BolusValidator.step(for: units, bridgeStep: s.effectiveBolusStep), reservoir: s.reservoirUnits
                )
            } catch {
                completion(.configuration(error as? LocalizedError))
                return
            }
            if s.isSuspended {
                completion(.deviceState(InsightPumpManagerError.pumpSuspended))
                return
            }

            self.transient.mutate { $0.bolus = .initiating }
            self.notifyStateDidChange()
            self.commandQueue.enqueue("bolus") { done in
                self.preflight { preflight in
                    self.queue.async {
                        func abort(_ error: PumpManagerError) {
                            self.transient.mutate { $0.bolus = nil }
                            self.notifyStateDidChange()
                            completion(error)
                            done()
                        }
                        if let error = preflight { abort(error)
                            return }
                        let s = self.state
                        if let error = self.dosingPrecondition(s) { abort(error)
                            return }
                        if s.isSuspended { abort(.deviceState(InsightPumpManagerError.pumpSuspended))
                            return }
                        if s.bolus?.phase == .inProgress { abort(.deviceState(InsightPumpManagerError.bolusInProgress))
                            return }
                        do {
                            try BolusValidator.validate(
                                units: units, maxBolus: s.effectiveMaxBolus,
                                step: BolusValidator.step(for: units, bridgeStep: s.effectiveBolusStep),
                                reservoir: s.reservoirUnits
                            )
                        } catch { abort(.configuration(error as? LocalizedError))
                            return }
                        self.sendBolus(units: units, decisionId: decisionId, activationType: activationType) { error in
                            completion(error)
                            done()
                        }
                    }
                }
            }
        }
    }

    private func sendBolus(
        units requested: Double, decisionId: UUID?, activationType: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        let requestId = UUID().uuidString
        let sentDate = clock()
        let automatic = activationType.isAutomatic
        let insulin = state.insulinTypeRaw.map(String.init)
        // Send the exact grid value of the amount-dependent step (1.2, not 1.2000000000000002).
        let units = Self.normalizedBolus(
            requested,
            step: BolusValidator.step(for: requested, bridgeStep: state.effectiveBolusStep)
        )

        // Record the intent *before* anything is sent. If the app dies now, the next launch knows.
        // Never overwrite a command that is still unresolved.
        let accepted = beginPending(PendingCommand(
            kind: .bolus, requestId: requestId, sentDate: sentDate, baselineSequence: state.lastHistorySequence,
            units: units, percent: nil, durationMinutes: nil, scheduledRate: nil, decisionId: decisionId,
            automatic: automatic, insulinType: insulin, isUncertain: false
        ))
        guard accepted else {
            transient.mutate { $0.bolus = nil }
            notifyStateDidChange()
            completion(.deviceState(InsightPumpManagerError.deliveryUncertain))
            return
        }
        persistNow()
        log.info("enact bolus \(units) U")

        client.deliverBolus(amount: units, requestId: requestId) { result in
            self.queue.async {
                switch result {
                case let .success(started):
                    // Record what the pump reports; a difference is surfaced.
                    let reported = started.amount.isFinite && started.amount > 0 ? started.amount : units
                    let mismatch = abs(reported - units) > 0.005
                    if mismatch {
                        self.log.warning("bridge reports a different bolus amount")
                        let alert = InsightAlertCatalog.bolusMismatchAlert(requested: units, actual: reported)
                        self.pumpDelegate.notify { delegate in
                            guard let delegate else { return }
                            Task { await delegate.issueAlert(alert) }
                        }
                    }
                    self.mutate { st in
                        if st.pendingCommand?.requestId == requestId { st.pendingCommand = nil }
                        st.bolus = UnfinalizedBolus(
                            requestId: requestId, units: reported, startDate: sentDate, bolusId: started.bolusId,
                            decisionId: decisionId, automatic: automatic, insulinType: insulin, deliveredUnits: 0,
                            phase: .inProgress, endDate: nil, programmedOnPump: false, acceptedAt: self.clock()
                        )
                    }
                    self.doseReporter = InsightDoseProgressReporter(total: reported)
                    self.transient.mutate { $0.bolus = nil }
                    self.armBolusWatch()
                    self.reportCurrentDoses(history: [], highest: nil)
                    self.notifyStateDidChange()
                    completion(nil)

                case let .failure(error):
                    self.transient.mutate { $0.bolus = nil }
                    if error.isUncertainOutcome {
                        completion(self.uncertainResult(requestId: requestId, error: error, recorded: true))
                    } else {
                        self.clearPending(requestId)
                        self.notifyStateDidChange()
                        completion(Self.pumpManagerError(from: error))
                    }
                }
            }
        }
    }

    // MARK: cancel bolus (risk reducing: never blocked by an unresolved command, goes first in the queue)

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        queue.async {
            let s = self.state
            let now = self.clock()
            // Cancel whenever the bolus may still be running: marked in progress, or (after an early "finished"
            // guess from a status) still inside its planned delivery time.
            if let bolus = s.bolus,
               bolus.phase == .inProgress || (!bolus.stopped && bolus.bolusId != nil && bolus.plannedEnd > now)
            {
                guard let bolusId = bolus.bolusId else {
                    completion(.failure(.communication(InsightPumpManagerError.bridgeProblem(
                        LocalizedString("The bolus cannot be cancelled yet.", comment: "Insight error")
                    ))))
                    return
                }
                self.sendCancelBolus(bolusId: bolusId, bolus: bolus, completion: completion)
                return
            }
            // A bolus whose start is unresolved (uncertain) or in flight: its id is unknown here, ask the bridge.
            let pending = s.pendingCommand.flatMap { $0.kind == .bolus ? $0 : nil }
            if pending != nil || self.transient.value.bolus == .initiating {
                self.cancelUnknownBolus(pending: pending, completion: completion)
                return
            }
            completion(.success(nil))
        }
    }

    private func sendCancelBolus(
        bolusId: Int,
        bolus: UnfinalizedBolus,
        completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void
    ) {
        transient.mutate { $0.bolus = .canceling }
        notifyStateDidChange()
        commandQueue.enqueue("cancelBolus", safety: true) { done in
            self.client.cancelBolus(bolusId: bolusId) { result in
                self.queue.async {
                    self.transient.mutate { $0.bolus = nil }
                    switch result {
                    case let .success(cancel):
                        let now = self.clock()
                        let delivered = cancel.delivered.map { min(max($0, 0), bolus.units) }
                        self.mutate { st in
                            guard var b = st.bolus else { return }
                            b.phase = .finished
                            b.stopped = true
                            b.endDate = now
                            b.deliveredUnits = delivered ?? b.units // unknown: assume all until the history says otherwise
                            st.bolus = b
                        }
                        self.doseReporter?.complete()
                        self.bolusWatch?.cancel()
                        self.bolusWatch = nil
                        self.reportCurrentDoses(history: [], highest: nil)
                        self.notifyStateDidChange()
                        self.refreshAll(reason: "bolus cancelled")
                        var dose: DoseEntry?
                        if let delivered {
                            dose = DoseEntry(
                                type: .bolus, startDate: bolus.startDate, endDate: now, value: bolus.units, unit: .units,
                                decisionId: bolus.decisionId, deliveredUnits: delivered, insulinType: self.state.insulinType,
                                automatic: bolus.automatic
                            )
                        }
                        completion(.success(dose))
                    case let .failure(error):
                        self.notifyStateDidChange()
                        self.refreshAll(reason: "cancel failed")
                        completion(.failure(Self.pumpManagerError(from: error)))
                    }
                    done()
                }
            }
        }
    }

    /// Cancel for a bolus we have no id for (start result unknown or still being sent): look it up in the status.
    /// Never reports success while a bolus might be running.
    private func cancelUnknownBolus(pending: PendingCommand?, completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        func unknown() -> PumpManagerError {
            .deviceState(InsightPumpManagerError.bridgeProblem(
                LocalizedString(
                    "The bolus is still being started and cannot be cancelled yet. Try again in a few seconds or suspend the pump.",
                    comment: "Insight error"
                )
            ))
        }
        guard let pending else {
            completion(.failure(unknown()))
            return
        }
        transient.mutate { $0.bolus = .canceling }
        notifyStateDidChange()
        commandQueue.enqueue("cancelUnknownBolus", safety: true) { done in
            self.client.getStatus { result in
                self.queue.async {
                    func finish(_ r: PumpManagerResult<DoseEntry?>) {
                        self.transient.mutate { $0.bolus = nil }
                        self.notifyStateDidChange()
                        completion(r)
                        done()
                    }
                    guard case let .success(raw) = result else {
                        finish(.failure(unknown()))
                        return
                    }
                    let status = raw.sanitized(now: self.clock())
                    self.applyStatus(status)
                    let units = pending.units ?? -1
                    let running = status.boluses
                        .first { abs($0.amount - units) < 0.005 } ?? (status.boluses.count == 1 ? status.boluses.first : nil)
                    if status.bolusesAreUnreadable {
                        finish(.failure(unknown()))
                    } else if let running {
                        self.client.cancelBolus(bolusId: running.bolusId) { cancelResult in
                            self.queue.async {
                                switch cancelResult {
                                case .success:
                                    self.resolvePendingCommandIfNeeded(reason: "bolus cancelled")
                                    self.refreshAll(reason: "bolus cancelled")
                                    finish(.success(nil))
                                case let .failure(error):
                                    finish(.failure(Self.pumpManagerError(from: error)))
                                }
                            }
                        }
                    } else if let at = status.timestamp, at > pending.sentDate {
                        finish(.success(nil)) // read after the start: no bolus is running
                    } else {
                        finish(.failure(unknown()))
                    }
                }
            }
        }
    }

    // MARK: temp basal

    public func enactTempBasal(
        decisionId: UUID?, unitsPerHour: Double, for duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        queue.async {
            let s = self.state
            if duration < 1 {
                // Cancelling a TBR only reduces delivery: it is never blocked by an unresolved command.
                if !s.isOnboarded { completion(.configuration(InsightPumpManagerError.notOnboarded))
                    return }
                self.cancelTempBasalCommand(decisionId: decisionId, completion: completion)
                return
            }
            if let error = self.dosingPrecondition(s) { completion(error)
                return }
            self.transient.mutate { $0.basal = .initiatingTempBasal }
            self.notifyStateDidChange()

            self.commandQueue.enqueue("tbr") { done in
                self.preflight { preflight in
                    self.queue.async {
                        func finish(_ error: PumpManagerError?) {
                            self.transient.mutate { $0.basal = nil }
                            self.notifyStateDidChange()
                            completion(error)
                            done()
                        }
                        if let error = preflight { finish(error)
                            return }
                        let s = self.state
                        if let error = self.dosingPrecondition(s) { finish(error)
                            return }
                        if s.isSuspended { finish(.deviceState(InsightPumpManagerError.pumpSuspended))
                            return }
                        guard let schedule = s.basalSchedule
                        else { finish(.configuration(InsightPumpManagerError.noBasalSchedule))
                            return }
                        guard s.basalScheduleSynced else { finish(.configuration(InsightPumpManagerError.scheduleNotConfirmed))
                            return }

                        let now = self.clock()
                        let utcOffset = s.pumpTimeZoneOffsetSeconds ?? s.pumpTimeZone.secondsFromGMT(for: now)
                        let pumpZone = TimeZone(secondsFromGMT: utcOffset) ?? s.pumpTimeZone
                        let scheduled = schedule.rate(at: now, in: pumpZone)
                        // Cross-check the base the percentage applies to with what the pump says. The pump's rate is
                        // compared with the schedule at the time it was read and now (with the pump clock drift):
                        // a boundary between the two must not look like a mismatch.
                        if let error = self.checkBasalRate(
                            schedule: schedule,
                            scheduledNow: scheduled,
                            now: now,
                            pumpZone: pumpZone
                        ) {
                            finish(error)
                            return
                        }
                        let maxBasal = [s.maxBasal, s.limits.maxBasal, InsightPumpSpec.maxBasalAbsolute].compactMap { $0 }
                            .min() ?? 25
                        if unitsPerHour > maxBasal + 1E-9 {
                            finish(.configuration(BolusValidationError.exceedsMaximum(maxBasal)))
                            return
                        }
                        let plan: TempBasalPlan
                        do {
                            plan = try TempBasalConverter.plan(
                                requestedRate: unitsPerHour, schedule: schedule, at: now, utcOffset: utcOffset, duration: duration
                            )
                        } catch {
                            finish(.configuration(error as? LocalizedError))
                            return
                        }
                        switch plan {
                        case .cancel:
                            self.transient.mutate { $0.basal = nil }
                            // A TBR that is only known from the bridge status (or whose status was unreadable)
                            // must be cancelled as well.
                            let mayBeRunning = s.runningTempBasal(at: now) != nil || self.lastStatus?.tbr != nil
                                || self.lastStatus?.tbrIsUnreadable == true
                            if !mayBeRunning {
                                self.notifyStateDidChange()
                                completion(nil)
                                done()
                            } else {
                                self.sendCancelTBR(safety: false) { error in completion(error)
                                    done() }
                            }
                        case let .set(percent, minutes, rate):
                            self.sendSetTBR(
                                percent: percent,
                                minutes: minutes,
                                expectedRate: rate,
                                scheduled: scheduled,
                                schedule: schedule,
                                utcOffset: utcOffset,
                                decisionId: decisionId
                            ) { error in
                                completion(error)
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    /// nil if the pump's reported basal rate agrees with the local schedule (or cannot be judged).
    /// A single disagreement only refuses this command; two consecutive fresh disagreements mark the profile as
    /// unconfirmed and raise an alert, so a transient glitch can never block temp basals for good.
    func checkBasalRate(
        schedule: InsightBasalSchedule,
        scheduledNow: Double,
        now: Date,
        pumpZone: TimeZone
    ) -> PumpManagerError? {
        guard let status = lastStatus, let pumpRate = status.basal?.rate, pumpRate.isFinite else { return nil } // unknown: ignore
        let readAt = status.timestamp ?? lastStatusReceived ?? now
        guard now.timeIntervalSince(readAt) < BridgeProtocol.staleStatusAge else { return nil }
        let drift = state.pumpTimeDriftSeconds ?? 0
        let candidates = [
            schedule.rate(at: readAt, in: pumpZone),
            schedule.rate(at: now.addingTimeInterval(drift.isFinite ? drift : 0), in: pumpZone),
            scheduledNow
        ]
        if candidates.contains(where: { abs(pumpRate - $0) <= 0.005 }) {
            if state.basalMismatchCount != 0 { mutate { $0.basalMismatchCount = 0 } }
            return nil
        }
        var count = state.basalMismatchCount
        if state.basalMismatchReadAt != readAt { count += 1 } // only a *new* read counts as another mismatch
        mutate { st in
            st.basalMismatchCount = count
            st.basalMismatchReadAt = readAt
            if count >= 2 { st.basalScheduleSynced = false }
        }
        if count >= 2 {
            let alert = InsightAlertCatalog.basalMismatchAlert(pump: pumpRate, local: scheduledNow)
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.issueAlert(alert) }
            }
            notifyStateDidChange()
        }
        return .configuration(InsightPumpManagerError.scheduleMismatch(pump: pumpRate, local: scheduledNow))
    }

    private func cancelTempBasalCommand(decisionId _: UUID?, completion: @escaping (PumpManagerError?) -> Void) {
        let s = state
        // If the status is old we cannot know that nothing runs: cancelling is harmless, so just do it.
        let statusAge = lastStatusReceived.map { clock().timeIntervalSince($0) } ?? .infinity
        guard s.runningTempBasal(at: clock()) != nil || lastStatus?.tbr != nil || lastStatus?
            .tbrIsUnreadable == true || statusAge > 60
        else {
            completion(nil)
            return
        }
        transient.mutate { $0.basal = .cancelingTempBasal }
        notifyStateDidChange()
        commandQueue.enqueue("cancelTBR", safety: true) { done in
            self.sendCancelTBR(safety: true) { error in
                completion(error)
                done()
            }
        }
    }

    private func sendSetTBR(
        percent: Int, minutes: Int, expectedRate _: Double, scheduled: Double, schedule: InsightBasalSchedule,
        utcOffset: Int, decisionId: UUID?,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        let requestId = UUID().uuidString
        let sentDate = clock()
        let accepted = beginPending(PendingCommand(
            kind: .setTBR, requestId: requestId, sentDate: sentDate, baselineSequence: state.lastHistorySequence,
            units: nil, percent: percent, durationMinutes: minutes, scheduledRate: scheduled, decisionId: decisionId,
            automatic: true, insulinType: state.insulinTypeRaw.map(String.init), isUncertain: false
        ))
        guard accepted else {
            transient.mutate { $0.basal = nil }
            notifyStateDidChange()
            completion(.deviceState(InsightPumpManagerError.deliveryUncertain))
            return
        }
        persistNow()
        log.info("set TBR \(percent)% for \(minutes) min")

        client.setTBR(percent: percent, duration: minutes, requestId: requestId) { result in
            self.queue.async {
                self.transient.mutate { $0.basal = nil }
                switch result {
                case let .success(set):
                    // Record what the pump reports, whatever it is; a difference is surfaced and re-read.
                    let actualPercent = (0 ... InsightPumpSpec.tbrMaxPercent).contains(set.percent) ? set.percent : percent
                    let actualMinutes = (1 ... InsightPumpSpec.tbrMaxMinutes).contains(set.duration) ? set.duration : minutes
                    let mismatch = set.percent != percent || set.duration != minutes
                    if mismatch {
                        self.log.warning("bridge set \(set.percent)%/\(set.duration) min instead of \(percent)%/\(minutes) min") }
                    self.mutate { st in
                        if st.pendingCommand?.requestId == requestId { st.pendingCommand = nil }
                        for i in st.tempBasals.indices where st.tempBasals[i].endedAt == nil {
                            st.tempBasals[i].endedAt = min(sentDate, st.tempBasals[i].plannedEnd)
                        }
                        st.tempBasals.append(ActiveTempBasal(
                            percent: actualPercent, durationMinutes: actualMinutes, start: sentDate, scheduledRate: scheduled,
                            effectiveRate: TempBasalConverter.effectiveRate(percent: actualPercent, scheduledRate: scheduled),
                            decisionId: decisionId, automatic: true, endedAt: nil,
                            schedule: schedule, utcOffsetSeconds: utcOffset
                        ))
                    }
                    self.scheduleTempBasalExpiryNotification()
                    self.reportCurrentDoses(history: [], highest: nil)
                    self.notifyStateDidChange()
                    if mismatch {
                        let alert = InsightAlertCatalog.tbrMismatchAlert(requested: percent, actual: set.percent)
                        self.pumpDelegate.notify { delegate in
                            guard let delegate else { return }
                            Task { await delegate.issueAlert(alert) }
                        }
                        self.refreshAll(reason: "temp basal differs from the request")
                    }
                    completion(nil)
                case let .failure(error):
                    if error.isUncertainOutcome {
                        completion(self.uncertainResult(requestId: requestId, error: error, recorded: true))
                    } else {
                        self.clearPending(requestId)
                        self.notifyStateDidChange()
                        completion(Self.pumpManagerError(from: error))
                    }
                }
            }
        }
    }

    /// `safety`: a user/Loop request to stop the TBR. It is sent even while another command is unresolved (then
    /// without a record of its own: the status is authoritative for the TBR and is re-read afterwards).
    private func sendCancelTBR(safety: Bool, completion: @escaping (PumpManagerError?) -> Void) {
        let requestId = UUID().uuidString
        let sentDate = clock()
        let recorded = beginPending(PendingCommand(
            kind: .cancelTBR, requestId: requestId, sentDate: sentDate, baselineSequence: state.lastHistorySequence,
            units: nil, percent: nil, durationMinutes: nil, scheduledRate: nil, decisionId: nil,
            automatic: true, insulinType: nil, isUncertain: false
        ))
        guard recorded || safety else {
            transient.mutate { $0.basal = nil }
            notifyStateDidChange()
            completion(.deviceState(InsightPumpManagerError.deliveryUncertain))
            return
        }
        if recorded { persistNow() }
        transient.mutate { $0.basal = .cancelingTempBasal }
        client.cancelTBR(requestId: requestId) { result in
            self.queue.async {
                self.transient.mutate { $0.basal = nil }
                switch result {
                case .success:
                    self.mutate { st in
                        if st.pendingCommand?.requestId == requestId { st.pendingCommand = nil }
                        for i in st.tempBasals.indices where st.tempBasals[i].endedAt == nil {
                            st.tempBasals[i].endedAt = min(sentDate, st.tempBasals[i].plannedEnd)
                        }
                    }
                    self.reportCurrentDoses(history: [], highest: nil)
                    self.notifyStateDidChange()
                    completion(nil)
                case let .failure(error):
                    if error.isUncertainOutcome {
                        completion(self.uncertainResult(requestId: requestId, error: error, recorded: recorded))
                    } else {
                        self.clearPending(requestId)
                        self.notifyStateDidChange()
                        completion(Self.pumpManagerError(from: error))
                    }
                }
            }
        }
    }

    // MARK: suspend / resume

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        changeOperatingMode(.stopped, completion: completion)
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        changeOperatingMode(.started, completion: completion)
    }

    /// Suspending only reduces delivery (`safety`): it is never blocked by an unresolved command and goes first.
    /// Resuming increases delivery and keeps every gate.
    private func changeOperatingMode(_ mode: PumpOperatingModeCommand, completion: @escaping (Error?) -> Void) {
        let safety = mode == .stopped
        queue.async {
            let s = self.state
            if safety {
                if !s.isOnboarded { completion(PumpManagerError.configuration(InsightPumpManagerError.notOnboarded))
                    return }
            } else if let error = self.dosingPrecondition(s) { completion(error)
                return }
            if mode == .stopped, s.isSuspended { completion(nil)
                return }
            if mode == .started, !s.isSuspended, s.operatingMode == .started { completion(nil)
                return }

            self.transient.mutate { $0.basal = mode == .stopped ? .suspending : .resuming }
            self.notifyStateDidChange()
            self.commandQueue.enqueue("mode", safety: safety) { done in
                let requestId = UUID().uuidString
                let sentDate = self.clock()
                // Re-check inside the queue: an earlier command may have become uncertain while this waited,
                // and its record must never be overwritten.
                let gate: Bool = safety || self.dosingPrecondition(self.state) == nil
                let recorded = gate && self.beginPending(PendingCommand(
                    kind: mode == .stopped ? .suspend : .resume, requestId: requestId, sentDate: sentDate,
                    baselineSequence: self.state.lastHistorySequence, units: nil, percent: nil, durationMinutes: nil,
                    scheduledRate: nil, decisionId: nil, automatic: false, insulinType: nil, isUncertain: false
                ))
                guard recorded || (safety && gate) else {
                    self.transient.mutate { $0.basal = nil }
                    self.notifyStateDidChange()
                    completion(PumpManagerError.deviceState(InsightPumpManagerError.deliveryUncertain))
                    done()
                    return
                }
                if recorded { self.persistNow() }
                self.client.setOperatingMode(mode, requestId: requestId) { result in
                    self.queue.async {
                        self.transient.mutate { $0.basal = nil }
                        switch result {
                        case .success:
                            self.mutate { st in
                                if st.pendingCommand?.requestId == requestId { st.pendingCommand = nil }
                                st.operatingMode = mode == .stopped ? .stopped : .started
                                st.suspendedSince = mode == .stopped ? sentDate : nil
                                st.modeChangedAt = sentDate
                            }
                            self.notifyStateDidChange()
                            self.refreshAll(reason: "mode changed")
                            completion(nil)
                        case let .failure(error):
                            if error.isUncertainOutcome {
                                completion(self.uncertainResult(requestId: requestId, error: error, recorded: recorded))
                            } else {
                                self.clearPending(requestId)
                                self.notifyStateDidChange()
                                completion(Self.pumpManagerError(from: error))
                            }
                        }
                        done()
                    }
                }
            }
        }
    }

    // MARK: record helpers

    /// Clears the in-flight record of `requestId` (and only that one).
    func clearPending(_ requestId: String) {
        mutate { st in
            if st.pendingCommand?.requestId == requestId { st.pendingCommand = nil }
        }
    }

    /// The result for a command whose outcome is unknown.
    /// - the record is still ours: mark it uncertain (it blocks further dosing until resolved)
    /// - a safety command that ran next to another unresolved command (no record of its own): re-read the status
    /// - the record was resolved by the user while the command was in flight: report the plain failure
    func uncertainResult(requestId: String, error: BridgeError, recorded: Bool) -> PumpManagerError {
        if state.pendingCommand?.requestId == requestId {
            markUncertain(requestId: requestId, error: error)
            return .uncertainDelivery
        }
        if !recorded {
            notifyStateDidChange()
            refreshAll(reason: "safety command outcome unknown")
            return .uncertainDelivery
        }
        notifyStateDidChange()
        return Self.pumpManagerError(from: error)
    }

    // MARK: basal schedule & limits

    public func syncBasalRateSchedule(
        items scheduleItems: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, Error>) -> Void
    ) {
        queue.async {
            let s = self.state
            let schedule: InsightBasalSchedule
            do {
                schedule = try InsightBasalSchedule.validated(
                    items: scheduleItems,
                    minRate: s.limits.minBasal ?? InsightPumpSpec.minBasal,
                    maxRate: min(s.limits.maxBasal ?? InsightPumpSpec.maxBasalAbsolute, InsightPumpSpec.maxBasalAbsolute)
                )
            } catch {
                completion(.failure(PumpManagerError.configuration(error as? LocalizedError)))
                return
            }
            self.pushBasalSchedule(schedule) { result in
                switch result {
                case .success:
                    let tz = self.state.pumpTimeZone
                    if let daily = DailyValueSchedule<Double>(dailyItems: scheduleItems, timeZone: tz) {
                        completion(.success(daily))
                    } else {
                        completion(.failure(PumpManagerError.configuration(BasalScheduleError.empty)))
                    }
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Writes `schedule` to the pump (profile 1). Used by Loop and by the manual "sync basal profile" action
    /// (`force`: rewrite and verify even if it is believed to be there already).
    func pushBasalSchedule(
        _ schedule: InsightBasalSchedule, force: Bool = false, completion: @escaping (Result<Void, PumpManagerError>) -> Void
    ) {
        mutate { $0.desiredBasalSchedule = schedule }
        commandQueue.enqueue("basalProfile") { done in
            // Re-checked inside the queue (see changeOperatingMode): no profile change on top of an unresolved command.
            if self.state.isDeliveryUncertain {
                completion(.failure(.deviceState(InsightPumpManagerError.deliveryUncertain)))
                done()
                return
            }
            // Nothing to write: the same profile is already confirmed on the pump.
            if !force, self.state.basalScheduleSynced, self.state.basalSchedule == schedule {
                completion(.success(()))
                done()
                return
            }
            let wasSynced = self.state.basalScheduleSynced
            // From the moment the write is sent the pump's profile is unknown until it is read back.
            self.mutate { $0.basalScheduleSynced = false }
            self.notifyStateDidChange()
            let requestId = UUID().uuidString
            self.client.setBasalProfile(segments: schedule.segments, requestId: requestId) { result in
                self.queue.async {
                    switch result {
                    case .success:
                        let now = self.clock()
                        self.mutate { st in
                            // late history events are costed with the schedule that was active at their time
                            if st.scheduleRevisions.isEmpty, let previous = st.basalSchedule {
                                st.scheduleRevisions.append(ScheduleRevision(effectiveFrom: .distantPast, schedule: previous))
                            }
                            st.scheduleRevisions.append(ScheduleRevision(effectiveFrom: now, schedule: schedule))
                            if st.scheduleRevisions.count > 8 { st.scheduleRevisions.removeFirst(st.scheduleRevisions.count - 8) }
                            // A running TBR keeps its percentage: from now on its rates come from the new profile.
                            for i in st.tempBasals.indices
                                where st.tempBasals[i].endedAt == nil && st.tempBasals[i].plannedEnd > now
                            {
                                st.tempBasals[i].laterSchedule = schedule
                                st.tempBasals[i].laterScheduleFrom = now
                            }
                            st.basalSchedule = schedule
                            st.basalScheduleSynced = true
                            st.bridgeBasalRate = nil // re-read with the next status
                            st.basalMismatchCount = 0
                        }
                        self.notifyStateDidChange()
                        self.refreshAll(reason: "basal profile")
                        completion(.success(()))
                    case let .failure(error):
                        // Unknown or unverified result: the profile on the pump is unknown, TBRs stay refused until it
                        // is synced again. A clean rejection leaves the pump as it was.
                        if !(error.isUncertainOutcome || self.isVerifyFailure(error)) {
                            self.mutate { $0.basalScheduleSynced = wasSynced }
                        }
                        self.notifyStateDidChange()
                        completion(.failure(Self.pumpManagerError(from: error)))
                    }
                    done()
                }
            }
        }
    }

    private func isVerifyFailure(_ error: BridgeError) -> Bool {
        if case let .remote(remote) = error { return remote.code == .verifyFailed }
        return false
    }

    public func syncDeliveryLimits(
        limits deliveryLimits: DeliveryLimits,
        completion: @escaping (Result<DeliveryLimits, Error>) -> Void
    ) {
        queue.async {
            // The bridge cannot change the pump's own limits: keep Loop's limits locally and never exceed the pump's.
            let s = self.state
            let requestedBolus = deliveryLimits.maximumBolus?.doubleValue(for: DoseEntry.units)
            let requestedBasal = deliveryLimits.maximumBasalRate?.doubleValue(for: DoseEntry.unitsPerHour)
            let bolus = [requestedBolus, s.limits.maxBolus, InsightPumpSpec.maxBolusAbsolute].compactMap { $0 }.min()
            let basal = [requestedBasal, s.limits.maxBasal, InsightPumpSpec.maxBasalAbsolute].compactMap { $0 }.min()
            self.mutate { st in
                st.maxBolus = bolus
                st.maxBasal = basal
            }
            self.notifyStateDidChange()
            completion(.success(DeliveryLimits(
                maximumBasalRate: basal.map { LoopQuantity(unit: DoseEntry.unitsPerHour, doubleValue: $0) },
                maximumBolus: bolus.map { LoopQuantity(unit: DoseEntry.units, doubleValue: $0) }
            )))
        }
    }

    // MARK: deletion

    public func delete() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.client.stop()
                if let bridgeId = self.state.bridgeId { self.credentialStore.delete(bridgeId: bridgeId) }
                self.bolusWatch?.cancel()
                self.disconnectTimer?.cancel()
                self.tbrExpiryTimer?.cancel()
                self.uncertaintyRetry?.cancel()
                continuation.resume()
            }
        }
        await pumpManagerDelegate?.pumpManagerWantsDeletion(self)
    }

    // MARK: helpers

    /// Common checks before any dosing command. Returns the error to hand to LoopKit.
    func dosingPrecondition(_ s: InsightPumpManagerState) -> PumpManagerError? {
        if !s.isOnboarded { return .configuration(InsightPumpManagerError.notOnboarded) }
        // Never dose on top of an unresolved command (safety invariant: no automatic retry).
        if s.isDeliveryUncertain { return .deviceState(InsightPumpManagerError.deliveryUncertain) }
        return nil
    }

    /// Refreshes the status if it is older than a minute and surfaces failures as certain (nothing was sent).
    /// Dosing is refused when the pump is not connected to the bridge or the pump data is older than 15 minutes.
    func preflight(_ completion: @escaping (PumpManagerError?) -> Void) {
        if let received = lastStatusReceived, clock().timeIntervalSince(received) < 60, client.sessionState == .ready,
           let status = lastStatus
        {
            completion(preflightVerdict(status))
            return
        }
        client.getStatus { result in
            self.queue.async {
                switch result {
                case let .success(status):
                    self.applyStatus(status)
                    self.notifyStateDidChange()
                    completion(self.preflightVerdict(status))
                case let .failure(error):
                    completion(Self.pumpManagerError(from: error))
                }
            }
        }
    }

    func preflightVerdict(_ status: BridgeStatus) -> PumpManagerError? {
        switch status.pumpLink {
        case .notPaired:
            return .configuration(BridgeError.remote(BridgeRemoteError(code: .notPaired, message: "", uncertain: false)))
        case .connected:
            break
        default:
            return .connection(BridgeError.remote(BridgeRemoteError(code: .pumpUnreachable, message: "", uncertain: false)))
        }
        if state.isStatusStale(now: clock()) {
            return .connection(InsightPumpManagerError.pumpDataStale)
        }
        return nil
    }

    /// Atomically records an in-flight command. Refuses (returns false) if *any* command is still recorded, so a
    /// command with an unknown result can never be overwritten.
    func beginPending(_ command: PendingCommand) -> Bool {
        var accepted = false
        mutate { st in
            if st.pendingCommand == nil {
                st.pendingCommand = command
                accepted = true
            }
        }
        return accepted
    }

    /// Rounds *down* to the bolus step grid and removes floating point noise (1.2, not 1.2000000000000002).
    static func normalizedBolus(_ units: Double, step: Double) -> Double {
        guard step > 0, units.isFinite else { return units }
        let steps = (units / step + 1E-6).rounded(.down)
        return (steps * step).rounded(toPlaces: 4)
    }

    static func pumpManagerError(from error: BridgeError) -> PumpManagerError {
        switch error {
        case .bluetoothUnavailable,
             .linkLost,
             .macMismatch,
             .missingCredentials,
             .notConnected,
             .sessionRejected,
             .timeout:
            return .connection(error)
        case let .remote(remote):
            switch remote.code {
            case .alertActive,
                 .busy,
                 .pumpBusy,
                 .pumpSuspended:
                return .deviceState(error)
            case .invalidArgs,
                 .limitExceeded,
                 .notPaired,
                 .unsupportedProtocol:
                return .configuration(error)
            case .pumpUnreachable:
                return .connection(error)
            default:
                return .communication(error)
            }
        default:
            return .communication(error)
        }
    }
}

private extension InsightPumpManagerState {
    /// A cached status says a TBR is active although we have no record (e.g. started on the pump).
    func lastStatus(isTbrActive status: BridgeStatus?) -> Bool {
        status?.tbr != nil
    }
}
