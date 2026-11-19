import Foundation
import LoopKit

// MARK: - Bridge client delegate

extension InsightPumpManager: InsightBridgeClientDelegate {
    public func bridgeClientDidChangeState(_: InsightBridgeClient) {
        queue.async { self.handleConnectionChange() }
    }

    public func bridgeClient(_: InsightBridgeClient, didReceive event: BridgeEvent) {
        queue.async { self.handle(event: event) }
    }

    func handleConnectionChange() {
        let connection = client.sessionState
        stateObservers.forEach { $0.connectionDidUpdate(connection) }

        if case .ready = connection {
            connectionLostSinceStore.value = nil
            disconnectTimer?.cancel()
            disconnectTimer = nil
            retractDisconnectAlertIfNeeded()
            if let hello = client.hello {
                mutate { st in
                    st.bridgeVersion = hello.bridgeVersion
                    if !hello.pumpPaired { st.pumpLink = .notPaired }
                }
            }
            refreshAll(reason: "session ready")
            resolvePendingCommandIfNeeded(reason: "session ready")
        } else {
            if connectionLostSinceStore.value == nil { connectionLostSinceStore.value = clock() }
            if state.isOnboarded { armDisconnectTimer() }
        }
        notifyStateDidChange()
    }

    /// The bridge authenticated under a (possibly new) BLE identifier: remember it, it is the starting point of the
    /// next reconnect (the address rotates, see PROTOCOL.md §1a).
    public func bridgeClient(_: InsightBridgeClient, didAdoptPeripheral id: UUID) {
        queue.async {
            guard self.state.peripheralIdentifier != id.uuidString else { return }
            self.mutate { $0.peripheralIdentifier = id.uuidString }
            self.notifyStateDidChange()
        }
    }

    private func handle(event: BridgeEvent) {
        switch event {
        case let .status(status):
            let delta = applyStatus(status)
            if delta.needsHistory { refreshHistoryOnly() }
            emitHeartbeatIfRequested()
            notifyStateDidChange()
        case let .alert(alert):
            reconcileAlert(alert)
            notifyStateDidChange()
        case let .bolusProgress(progress):
            guard var bolus = state.bolus, bolus.phase == .inProgress,
                  bolus.bolusId == nil || bolus.bolusId == progress.bolusId,
                  progress.delivered.isFinite, progress.delivered >= 0
            else { return }
            bolus.deliveredUnits = max(bolus.deliveredUnits, min(progress.delivered, bolus.units))
            mutate { $0.bolus = bolus }
            doseReporter?.notify(deliveredUnits: bolus.deliveredUnits)
        case let .pumpLink(link):
            mutate { $0.pumpLink = link }
            notifyStateDidChange()
        case .unknown:
            break
        }
    }

    // MARK: unreachable alert

    private func armDisconnectTimer() {
        guard disconnectTimer == nil else { return }
        disconnectTimer = scheduler.schedule(after: 10 * 60) { [weak self] in
            guard let self else { return }
            self.disconnectTimer = nil
            guard self.state.isOnboarded, self.client.sessionState != .ready, !self.state.disconnectAlertIssued else { return }
            self.mutate { $0.disconnectAlertIssued = true }
            let alert = InsightAlertCatalog.bridgeDisconnectedAlert()
            self.pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.issueAlert(alert) }
            }
            self.notifyStateDidChange()
        }
    }

    private func retractDisconnectAlertIfNeeded() {
        guard state.disconnectAlertIssued else { return }
        mutate { $0.disconnectAlertIssued = false }
        let id = Alert.Identifier(
            managerIdentifier: InsightAlertCatalog.managerIdentifier,
            alertIdentifier: InsightAlertCatalog.disconnectedAlertIdentifier
        )
        pumpDelegate.notify { delegate in
            guard let delegate else { return }
            Task { await delegate.retractAlert(identifier: id) }
        }
    }

    // MARK: - Status

    struct StatusDelta {
        var needsHistory = false
        var bolusEnded = false
    }

    /// Merges a bridge status into the state. Never blindly trusts an old cached status over newer knowledge.
    @discardableResult func applyStatus(_ received: BridgeStatus) -> StatusDelta {
        var delta = StatusDelta()
        let now = clock()
        // A status from the future (broken bridge clock) must not win the "newest status" race or look fresh.
        let s = received.sanitized(now: now)
        if s.timestamp == nil, received.timestamp != nil { log.warning("status timestamp is in the future: ignored") }
        let before = state

        // A status that was read before the one already applied says nothing new (and could undo newer
        // knowledge): it only proves that the bridge is reachable.
        // (an applied read time from the future, e.g. from an older build, is not trusted either)
        let applied = before.lastPumpReadDate.flatMap { $0 > now.addingTimeInterval(BridgeStatus.maxClockSkew) ? nil : $0 }
        if let t = s.timestamp, let applied, t < applied {
            log.info("ignoring a status older than the one already applied")
            mutate { $0.lastBridgeContact = now }
            return delta
        }

        lastStatus = s
        lastStatusReceived = now

        var replaced = false
        let newState = mutate { st in
            st.lastStatusDate = now
            st.lastBridgeContact = now
            if let t = s.timestamp { st.lastPumpReadDate = t }
            st.pumpLink = s.pumpLink

            if let serial = s.serial, !serial.isEmpty {
                if let old = st.pumpSerial, old != serial { replaced = true }
                st.pumpSerial = serial
                st.isSimulated = serial == InsightPumpManager.simulatorSerial
            }
            if let fw = s.firmware { st.pumpFirmware = fw }
            if let b = s.battery?.percent, b.isFinite { st.batteryPercent = min(max(b, 0), 100) }
            if let r = s.reservoir?.units, r.isFinite, r >= 0 { st.reservoirUnits = r }
            if let rate = s.basal?.rate, rate.isFinite {
                st.bridgeBasalRate = rate
                st.bridgeBasalReadAt = s.timestamp ?? now
            }
            st.activePumpAlert = s.activeAlert

            if let limits = s.limits {
                st.limits = PumpLimitsState(
                    maxBolus: limits.maxBolus, maxBasal: limits.maxBasal, bolusStep: limits.bolusStep,
                    basalStep: limits.basalStep, minBasal: limits.minBasal
                )
            }
            if let drift = s.pumpTime?.driftSeconds, drift.isFinite { st.pumpTimeDriftSeconds = drift }
            if let offset = Self.pumpOffset(s.pumpTime) { st.pumpTimeZoneOffsetSeconds = offset }

            if replaced {
                st.lastHistorySequence = nil
                st.basalScheduleSynced = false
                st.profileWriteFailed = nil
                st.tempBasals = []
                st.finalizedLocal = []
                st.finalizedBolusIds = []
                st.bolus = nil
            }

            let modeIsStale = (s.timestamp.map { t in st.modeChangedAt.map { t < $0 } ?? false }) ?? false
            if s.operatingMode != .unknown, !modeIsStale {
                let wasSuspended = st.isSuspended
                st.operatingMode = s.operatingMode
                if st.isSuspended, !wasSuspended { st.suspendedSince = s.timestamp ?? now }
                if !st.isSuspended { st.suspendedSince = nil }
            }

            Self.reconcileTempBasal(&st, status: s, now: now)
            delta.bolusEnded = Self.reconcileBolus(&st, status: s, now: now, reporter: doseReporter)

            if let seq = s.lastHistorySequence {
                if let last = st.lastHistorySequence { delta.needsHistory = seq > last } else { delta.needsHistory = true }
            }
            if delta.bolusEnded { delta.needsHistory = true }
        }

        if let units = newState.reservoirUnits, let at = s.timestamp ?? Optional(now) { reportReservoir(units: units, at: at) }
        if replaced {
            log.warning("pump serial changed: treating as a new pump")
            pumpDelegate.notify { [weak self] delegate in
                guard let self else { return }
                delegate?.pumpManagerPumpWasReplaced(self)
            }
        }
        if delta.bolusEnded {
            doseReporter?.complete()
            bolusWatch?.cancel()
            bolusWatch = nil
        }
        if before.activePumpAlert != s.activeAlert || before.activeAlerts.isEmpty != (s.activeAlert == nil) {
            reconcileAlert(s.activeAlert)
        }
        scheduleTempBasalExpiryNotification()
        return delta
    }

    static let simulatorSerial = "SIMULATOR"

    /// Pump local offset from UTC derived from `pumpTime` (rounded to 15 minutes), nil if not parsable.
    static func pumpOffset(_ pumpTime: BridgeStatus.PumpTime?) -> Int? {
        guard let utc = pumpTime?.utc, let local = pumpTime?.pumpLocal else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let naive = f.date(from: String(local.prefix(19))) else { return nil }
        let diff = naive.timeIntervalSince(utc)
        guard let steps = (diff / 900).rounded().exactInt, abs(steps) <= 14 * 4 else { return nil }
        return steps * 900
    }

    private static func reconcileTempBasal(_ st: inout InsightPumpManagerState, status s: BridgeStatus, now: Date) {
        // Unparseable is *unknown*, not "no TBR": leave everything as it is.
        guard !s.tbrIsUnreadable else { return }
        let tz = st.pumpTimeZone
        if let t = s.tbr {
            guard t.percent >= 0, t.percent <= InsightPumpSpec.tbrMaxPercent, t.duration > 0,
                  t.duration <= InsightPumpSpec.tbrMaxMinutes else { return }
            let remaining = min(t.remaining ?? t.duration, t.duration)
            let start = t.start ?? now.addingTimeInterval(-Double(t.duration - remaining) * 60)
            // The same TBR may be stamped slightly differently by the pump (clock drift): tolerance = 3 min + drift,
            // compared at the start or at the end.
            let tolerance = 180 + abs(st.pumpTimeDriftSeconds ?? 0)
            let end = start.addingTimeInterval(TimeInterval(t.duration) * 60)
            if st.tempBasals.contains(where: {
                $0.endedAt == nil && $0.percent == t.percent
                    &&
                    (
                        abs($0.start.timeIntervalSince(start)) < tolerance || abs($0.plannedEnd.timeIntervalSince(end)) <
                            tolerance
                    )
            }) {
                return
            }
            for i in st.tempBasals.indices where st.tempBasals[i].endedAt == nil {
                st.tempBasals[i].endedAt = min(now, max(start, st.tempBasals[i].start))
            }
            let schedule = st.schedule(at: start)
            let scheduled = schedule?.rate(at: start, in: tz) ?? st.bridgeBasalRate ?? 0
            st.tempBasals.append(ActiveTempBasal(
                percent: t.percent, durationMinutes: t.duration, start: start, scheduledRate: scheduled,
                effectiveRate: TempBasalConverter.effectiveRate(percent: t.percent, scheduledRate: scheduled),
                decisionId: nil, automatic: false, endedAt: nil,
                schedule: schedule, utcOffsetSeconds: st.pumpTimeZoneOffsetSeconds ?? tz.secondsFromGMT(for: start)
            ))
        } else if let readAt = s.timestamp {
            // Only a status read *after* the TBR started can tell that it is gone.
            for i in st.tempBasals.indices
                where st.tempBasals[i].endedAt == nil && readAt > st.tempBasals[i].start.addingTimeInterval(1)
            {
                st.tempBasals[i].endedAt = min(now, st.tempBasals[i].plannedEnd)
            }
        }
    }

    /// Statuses that must show our bolus missing before it counts as finished.
    static let bolusMissesRequired = 2

    /// Returns true when our bolus was seen finishing.
    private static func reconcileBolus(
        _ st: inout InsightPumpManagerState, status s: BridgeStatus, now: Date, reporter: InsightDoseProgressReporter?
    ) -> Bool {
        // Unparseable is *unknown*, not "no bolus": neither end nor adopt anything.
        guard !s.bolusesAreUnreadable else { return false }

        if var b = st.bolus, b.phase == .inProgress {
            let active = s.boluses.first { a in
                if let id = b.bolusId { return a.bolusId == id }
                return abs(a.amount - b.units) < 0.005
            }
            if let a = active {
                b.deliveredUnits = max(b.deliveredUnits, min(a.amount - a.remaining, b.units))
                if b.bolusId == nil { b.bolusId = a.bolusId }
                b.missCount = 0
                reporter?.notify(deliveredUnits: b.deliveredUnits)
                st.bolus = b
                return false
            }
            // A miss only counts when the status was read after the bridge accepted the bolus: an older cached
            // status cannot know about it. Two consecutive misses are needed.
            if let readAt = s.timestamp, readAt > (b.acceptedAt ?? b.startDate) { b.missCount += 1 }
            let goneForSure = b.missCount >= bolusMissesRequired
            // Fallback for bridges without usable timestamps: long after the bolus must have ended.
            let overdue = now > b.plannedEnd.addingTimeInterval(5 * 60)
            if goneForSure || overdue {
                b.phase = .finished
                b.endDate = min(now, b.plannedEnd.addingTimeInterval(60))
                b.deliveredUnits = b.units // assume complete until the history says otherwise (conservative IOB)
                st.bolus = b
                return true
            }
            st.bolus = b
            return false
        }
        if st.bolus == nil, let ext = s.boluses.first(where: { $0.amount > 0 && !st.finalizedBolusIds.contains($0.bolusId) }) {
            let delivered = max(ext.amount - ext.remaining, 0)
            st.bolus = UnfinalizedBolus(
                requestId: "pump-\(ext.bolusId)", units: ext.amount,
                startDate: now.addingTimeInterval(-InsightPumpManager.deliveryDuration(units: delivered)),
                bolusId: ext.bolusId, decisionId: nil, automatic: false, insulinType: st.insulinTypeRaw.map(String.init),
                deliveredUnits: delivered, phase: .inProgress, endDate: nil, programmedOnPump: true, acceptedAt: now
            )
        }
        return false
    }

    // MARK: - Refresh (status + history)

    /// Reads status and new history. Runs through the command queue so it never interleaves with dosing.
    func refreshAll(reason: String, completion: ((Result<Void, BridgeError>) -> Void)? = nil) {
        commandQueue.enqueue("refresh") { done in
            self.client.getStatus { result in
                self.queue.async {
                    switch result {
                    case let .failure(error):
                        self.log.warning("status refresh failed (\(reason))")
                        self.notifyStateDidChange()
                        completion?(.failure(error))
                        done()
                    case let .success(status):
                        let delta = self.applyStatus(status)
                        self.syncHistory(
                            status: status,
                            force: delta.needsHistory || self.state.bolus != nil || !self.state.tempBasals.isEmpty
                        ) { historyResult in
                            self.finishRefresh()
                            completion?(historyResult)
                            done()
                        }
                    }
                }
            }
        }
    }

    private func refreshHistoryOnly() {
        guard !historySyncInFlight else { return }
        commandQueue.enqueue("history") { done in
            self.syncHistory(status: self.lastStatus, force: true) { _ in
                self.finishRefresh()
                done()
            }
        }
    }

    private func finishRefresh() {
        notifyStateDidChange()
        maybeSyncTimeAutomatically()
        maybeResyncProfileAutomatically()
        armBolusWatch()
        scheduleTempBasalExpiryNotification()
    }

    // MARK: - Profile self-healing

    static let profileResyncInterval: TimeInterval = 10 * 60

    /// Temp basals are refused while the pump profile is not confirmed. When the only reason is that a write did not
    /// finish cleanly (not that the pump contradicted Trio's profile), the last requested profile is written again, at
    /// most every 10 minutes, so that looping does not wait for a manual "Sync basal profile".
    /// At most this many automatic writes per profile, then the user is told to sync by hand.
    static let maxAutoProfileResyncs = 3

    func maybeResyncProfileAutomatically() {
        let s = state
        guard s.isOnboarded, !s.basalScheduleSynced, s.profileWriteFailed == true, s.basalMismatchCount < 2,
              s.pendingCommand == nil, client.sessionState == .ready, s.bolus?.phase != .inProgress,
              let schedule = s.desiredBasalSchedule ?? s.basalSchedule else { return }
        let now = clock()
        // Never rewrite the profile under a running temp basal (the pump keeps its percentage).
        if s.runningTempBasal(at: now) != nil || lastStatus?.tbr != nil { return }
        if let last = lastProfileAutoResync, now.timeIntervalSince(last) < Self.profileResyncInterval { return }
        if autoResyncAttempts >= Self.maxAutoProfileResyncs {
            // Give up quietly no longer: say so once and leave it to the user.
            mutate { $0.profileWriteFailed = nil }
            let alert = InsightAlertCatalog.loopBlockedAlert(reason: LocalizedString(
                "Trio could not confirm the basal profile on the pump after several tries. Open the pump settings and tap Sync basal profile.",
                comment: "Alert body"
            ))
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.issueAlert(alert) }
            }
            notifyStateDidChange()
            return
        }
        lastProfileAutoResync = now
        autoResyncAttempts += 1
        log.info("basal profile not confirmed: writing it again automatically (\(autoResyncAttempts))")
        pushBasalSchedule(schedule, force: true) { [weak self] result in
            if case .failure = result { self?.log.warning("automatic profile write failed") }
        }
    }

    // MARK: - History

    private static let firstSyncLookback: TimeInterval = 8 * 3600
    /// How long an unreadable history event blocks the cursor before it is skipped.
    static let unreadableSkipAfter: TimeInterval = 30 * 60
    private static let initialHistoryWindow = 150

    private func syncHistory(status: BridgeStatus?, force: Bool, completion: @escaping (Result<Void, BridgeError>) -> Void) {
        let last = state.lastHistorySequence
        if let last, let statusSeq = status?.lastHistorySequence, statusSeq <= last, !force {
            reportCurrentDoses(history: [], highest: nil, completion: { completion(.success(())) })
            return
        }
        historySyncInFlight = true
        let since = last ?? status?.lastHistorySequence.map { max($0 - Self.initialHistoryWindow, 0) }
        readPages(since: since, accumulated: [], unreadable: [], pages: 0) { result in
            self.queue.async {
                self.historySyncInFlight = false
                switch result {
                case let .failure(error):
                    self.log.warning("history read failed")
                    completion(.failure(error))
                case let .success(page):
                    self.process(
                        history: page.events,
                        unreadable: page.unreadable,
                        pageLast: page.lastSequence,
                        complete: !page.more
                    ) {
                        completion(.success(()))
                    }
                }
            }
        }
    }

    struct HistoryPages {
        var events: [HistoryEvent]
        var unreadable: [UnreadableHistoryEvent]
        var lastSequence: Int
        var more: Bool
    }

    func readPages(
        since: Int?, accumulated: [HistoryEvent], unreadable: [UnreadableHistoryEvent], pages: Int,
        completion: @escaping (Result<HistoryPages, BridgeError>) -> Void
    ) {
        client.readHistory(since: since, max: BridgeProtocol.historyPageSize) { result in
            self.queue.async {
                switch result {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(page):
                    if page.skippedEvents > 0 { self.log.warning("\(page.skippedEvents) unreadable history events") }
                    let all = accumulated + page.events
                    let bad = unreadable + page.unreadable
                    let highest = page.events.map(\.seq).max()
                    // Continue only if the page made progress (guards against a bridge that never advances).
                    // A waiting safety command (suspend / cancel) must not sit behind a long history read.
                    if page.more, self.commandQueue.hasSafetyWaiting {
                        completion(.success(HistoryPages(
                            events: all,
                            unreadable: bad,
                            lastSequence: page.lastSequence,
                            more: true
                        )))
                    } else if page.more, pages < 19, let highest, highest > (since ?? -1) {
                        self.readPages(
                            since: highest,
                            accumulated: all,
                            unreadable: bad,
                            pages: pages + 1,
                            completion: completion
                        )
                    } else {
                        completion(.success(HistoryPages(
                            events: all,
                            unreadable: bad,
                            lastSequence: page.lastSequence,
                            more: page.more
                        )))
                    }
                }
            }
        }
    }

    func process(
        history rawEvents: [HistoryEvent], unreadable: [UnreadableHistoryEvent] = [], pageLast: Int, complete: Bool,
        completion: @escaping () -> Void
    ) {
        let now = clock()
        let current = state
        var fresh = HistoryMapper.newEvents(rawEvents, after: current.lastHistorySequence)
        if current.lastHistorySequence == nil {
            fresh = fresh.filter { now.timeIntervalSince($0.time) <= Self.firstSyncLookback }
        }
        // An uncertain bolus acts as the candidate that a matching history event belongs to.
        var candidate = current.bolus
        if candidate == nil, let p = current.pendingCommand, p.kind == .bolus, p.isUncertain, let units = p.units {
            candidate = UnfinalizedBolus(
                requestId: p.requestId, units: units, startDate: p.sentDate, bolusId: nil, decisionId: p.decisionId,
                automatic: p.automatic, insulinType: p.insulinType, deliveredUnits: 0, phase: .inProgress,
                endDate: nil, programmedOnPump: false
            )
        }
        let context = HistoryMappingContext(
            serial: current.pumpSerial ?? "unknown", schedule: current.basalSchedule, timeZone: current.pumpTimeZone,
            insulinType: current.insulinType, bolus: candidate, tempBasals: current.tempBasals,
            scheduleRevisions: current.scheduleRevisions, finalizedLocal: current.finalizedLocal
        )
        let skipped = Set(current.skippedHistorySequences)
        var mapped = HistoryMapper.map(fresh.filter { !skipped.contains($0.seq) }, context: context)
        matchedPendingBolus = current.bolus == nil && candidate != nil && mapped.matchedBolusEvent != nil

        // Events that could not even be decoded: an unreadable bolus is counted as delivered in full.
        var unreadableSequences = mapped.unreadableSequences.filter { !skipped.contains($0) }
        var unknownSequenceUnreadable = false
        for item in unreadable {
            if let seq = item.seq {
                if skipped.contains(seq) { continue }
                if seq > (current.lastHistorySequence ?? -1) { unreadableSequences.append(seq) }
            } else {
                unknownSequenceUnreadable = true
            }
            if let conservative = HistoryMapper.conservativeEvent(for: item, context: context, now: now) {
                mapped.events.append(conservative)
            }
        }
        var hasUnreadable = !unreadableSequences.isEmpty || unknownSequenceUnreadable

        // A permanently unreadable event must not stall history for good: after a while it is skipped (its
        // conservative dose stays reported, the sequence number is remembered).
        var skipNow = false
        if hasUnreadable {
            if let since = current.unreadableSince {
                skipNow = now.timeIntervalSince(since) > Self.unreadableSkipAfter
            }
        }
        mutate { st in
            if mapped.matchedBolusEvent != nil { st.bolus = nil }
            if matchedPendingBolus { st.pendingCommand?.historyMatched = true }
            st.tempBasals.removeAll { mapped.matchedTempBasalStarts.contains($0.start) }
            st.finalizedLocal.removeAll { mapped.matchedFinalizedKeys.contains($0.key) }
            for id in mapped.finalizedBolusIds where !st.finalizedBolusIds.contains(id) { st.finalizedBolusIds.append(id) }
            if st.finalizedBolusIds.count > 40 { st.finalizedBolusIds.removeFirst(st.finalizedBolusIds.count - 40) }
            if hasUnreadable {
                if st.unreadableSince == nil { st.unreadableSince = now }
                if skipNow {
                    for seq in unreadableSequences
                        where !st.skippedHistorySequences.contains(seq) { st.skippedHistorySequences.append(seq) }
                    if st.skippedHistorySequences
                        .count > 50 { st.skippedHistorySequences.removeFirst(st.skippedHistorySequences.count - 50) }
                    if unknownSequenceUnreadable { st.unreadableSince = now } // restart the clock for sequence-less ones
                }
            } else {
                st.unreadableSince = nil
            }
        }
        if mapped.matchedBolusEvent != nil {
            doseReporter?.complete()
            doseReporter = nil
        }
        if skipNow {
            log
                .warning(
                    "skipping unreadable history events \(unreadableSequences) after \(Int(Self.unreadableSkipAfter / 60)) min"
                )
            unreadableSequences = []
            unknownSequenceUnreadable = false
            hasUnreadable = false
        }
        reconcileUnreadableHistoryAlert(hasUnreadable)

        // History events seen so far are remembered even if there was nothing to report.
        let highest = mapped.highestSequence ?? (complete ? pageLast : nil)
        var sequenceToStore = [highest, current.lastHistorySequence].compactMap { $0 }.max()
        // Never move past an event that could not be read: it is re-read (and re-reported, deduplicated by its
        // sync identifier) until the bridge delivers it in a readable form.
        if unknownSequenceUnreadable {
            sequenceToStore = current.lastHistorySequence
        } else if let firstBad = unreadableSequences.min() {
            sequenceToStore = [sequenceToStore, firstBad - 1].compactMap { $0 }.min()
        }
        // While a command is uncertain, keep re-reading everything after the point where it was sent.
        if let p = current.pendingCommand, p.isUncertain {
            sequenceToStore = p.baselineSequence.map { base in sequenceToStore.map { min($0, base) } ?? base }
        }
        lastHistoryEvents = fresh
        reportCurrentDoses(history: mapped.events, highest: sequenceToStore, completion: completion)
    }

    /// One alert while history events cannot be read (the user should look at the pump history).
    func reconcileUnreadableHistoryAlert(_ hasUnreadable: Bool) {
        let issued = state.unreadableHistoryAlertIssued
        guard hasUnreadable != issued else { return }
        mutate { $0.unreadableHistoryAlertIssued = hasUnreadable }
        if hasUnreadable {
            let alert = InsightAlertCatalog.unreadableHistoryAlert()
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.issueAlert(alert) }
            }
        } else {
            let id = Alert.Identifier(
                managerIdentifier: InsightAlertCatalog.managerIdentifier,
                alertIdentifier: InsightAlertCatalog.unreadableHistoryAlertIdentifier
            )
            pumpDelegate.notify { delegate in
                guard let delegate else { return }
                Task { await delegate.retractAlert(identifier: id) }
            }
        }
    }

    // MARK: - Reporting to LoopKit

    /// How long after its end a dose may stay "waiting for the history" before we finalize it ourselves.
    static let historyGrace: TimeInterval = 10 * 60
    private static let finalizedLocalRetention: TimeInterval = 48 * 3600

    /// Sends finalized history events plus every dose that is still in flight (as mutable doses).
    /// `replacePendingEvents` is always true because we always send the complete set of mutable doses.
    func reportCurrentDoses(history: [NewPumpEvent], highest: Int?, completion: (() -> Void)? = nil) {
        let now = clock()
        var events = history
        var localFinalized = [NewPumpEvent]()
        let snapshot = state
        let serial = snapshot.pumpSerial ?? "unknown"
        let grace = Self.historyGrace
        let bolusTitle = LocalizedString("Bolus", comment: "Pump event")
        let tbrTitle = LocalizedString("Temp Basal", comment: "Pump event")
        var newlyFinalized = [FinalizedLocalDose]()

        var bolusToClear: UnfinalizedBolus?
        if let b = snapshot.bolus {
            if b.phase == .finished, now > (b.endDate ?? b.expectedEnd).addingTimeInterval(grace) {
                // The pump history never produced the matching event: keep the dose (never lose IOB). The same
                // sync identifier is used if the history event shows up later.
                let dose = DoseFactory.bolusDose(b, mutable: false, insulinType: snapshot.insulinType)
                localFinalized.append(DoseFactory.event(for: dose, key: b.syncKey(serial: serial), title: bolusTitle))
                newlyFinalized.append(FinalizedLocalDose(
                    kind: .bolus, key: b.syncKey(serial: serial), start: dose.startDate, end: dose.endDate,
                    bolusId: b.bolusId, units: b.units, percent: nil, finalizedAt: now
                ))
                bolusToClear = b
            } else {
                var dose = DoseFactory.bolusDose(b, mutable: true, insulinType: snapshot.insulinType)
                if b.phase == .finished { dose.endDate = max(b.endDate ?? b.expectedEnd, dose.startDate) }
                events.append(DoseFactory.event(for: dose, key: b.syncKey(serial: serial), title: bolusTitle))
            }
        } else if let p = snapshot.pendingCommand, p.kind == .bolus, p.isUncertain, !p.historyMatched, let units = p.units {
            // Assume it was delivered until proven otherwise (unless the history already delivered the dose).
            let dose = DoseEntry(
                type: .bolus, startDate: p.sentDate,
                endDate: p.sentDate.addingTimeInterval(InsightPumpManager.deliveryDuration(units: units)),
                value: units, unit: .units, decisionId: p.decisionId,
                insulinType: snapshot.insulinType, automatic: p.automatic, isMutable: true
            )
            events.append(DoseFactory.event(for: dose, key: "insight-local:\(serial):bolus:\(p.requestId)", title: bolusTitle))
        }

        var tbrsToClear = [Date]()
        for tbr in snapshot.tempBasals {
            let key = tbr.syncKey(serial: serial)
            if !tbr.isRunning(at: now), now > tbr.end.addingTimeInterval(grace) {
                let dose = DoseFactory.tempBasalDose(tbr, mutable: false, insulinType: snapshot.insulinType, endDate: tbr.end)
                localFinalized.append(DoseFactory.event(for: dose, key: key, title: tbrTitle))
                newlyFinalized.append(FinalizedLocalDose(
                    kind: .tempBasal, key: key, start: tbr.start, end: tbr.end, bolusId: nil, units: nil,
                    percent: tbr.percent, finalizedAt: now
                ))
                tbrsToClear.append(tbr.start)
            } else {
                let dose = DoseFactory.tempBasalDose(tbr, mutable: true, insulinType: snapshot.insulinType, endDate: tbr.end)
                events.append(DoseFactory.event(for: dose, key: key, title: tbrTitle))
            }
        }
        events += localFinalized

        if bolusToClear != nil || !tbrsToClear.isEmpty || !snapshot.finalizedLocal.isEmpty {
            mutate { st in
                if let cleared = bolusToClear {
                    st.bolus = nil
                    if let id = cleared.bolusId, !st.finalizedBolusIds.contains(id) { st.finalizedBolusIds.append(id) }
                }
                st.tempBasals.removeAll { tbrsToClear.contains($0.start) }
                st.finalizedLocal.append(contentsOf: newlyFinalized)
                st.finalizedLocal.removeAll { now.timeIntervalSince($0.finalizedAt) > Self.finalizedLocalRetention }
                if st.finalizedLocal.count > 30 { st.finalizedLocal.removeFirst(st.finalizedLocal.count - 30) }
            }
            if bolusToClear != nil { doseReporter = nil }
        }

        pumpDelegate.notify { [weak self] delegate in
            guard let self else { return }
            guard let delegate else {
                self.log.error("events could not be reported: no delegate")
                return
            }
            delegate.pumpManager(
                self, hasNewPumpEvents: events, lastReconciliation: now, replacePendingEvents: true
            ) { error in
                self.queue.async {
                    if let error {
                        self.log.error("delegate rejected pump events: \(String(describing: error))")
                    } else {
                        self.mutate { st in
                            if let highest { st.lastHistorySequence = max(st.lastHistorySequence ?? highest, highest) }
                            st.lastHistoryRead = now
                        }
                    }
                    self.notifyStateDidChange()
                }
            }
        }
        // The command queue must never wait for the delegate (it may be slow or stuck): the sequence number is only
        // stored once the delegate acknowledged, so nothing is lost by continuing right away.
        queue.async { completion?() }
    }

    // MARK: - Bolus watch / TBR expiry

    func armBolusWatch() {
        bolusWatch?.cancel()
        bolusWatch = nil
        guard let bolus = state.bolus, bolus.phase == .inProgress else { return }
        let wait = max(bolus.expectedEnd.timeIntervalSince(clock()) + 10, 20)
        bolusWatch = scheduler.schedule(after: min(wait, 60)) { [weak self] in
            guard let self else { return }
            self.bolusWatch = nil
            guard let b = self.state.bolus, b.phase == .inProgress else { return }
            self.refreshAll(reason: "bolus watch")
        }
    }

    func scheduleTempBasalExpiryNotification() {
        tbrExpiryTimer?.cancel()
        tbrExpiryTimer = nil
        guard let tbr = state.runningTempBasal(at: clock()) else { return }
        let wait = max(tbr.plannedEnd.timeIntervalSince(clock()) + 1, 1)
        tbrExpiryTimer = scheduler.schedule(after: wait) { [weak self] in
            guard let self else { return }
            self.tbrExpiryTimer = nil
            self.notifyStateDidChange()
            self.refreshHistoryOnly()
        }
    }
}
