import Foundation
import LoopKit

/// APIs used by the setup flow and the settings screen.
public extension InsightPumpManager {
    // MARK: scanning & pairing

    func startScan(delegate: BridgeScanDelegate) {
        queue.async { self.client.startScan(delegate: delegate) }
    }

    func stopScan() {
        queue.async { self.client.stopScan() }
    }

    /// Pairs with `device` (§4.1). `handler` is called on the main queue.
    func beginPairing(with device: DiscoveredBridge, handler: @escaping (PairingEvent) -> Void) {
        queue.async {
            self.client.stopScan()
            let previousBridge = self.state.bridgeId
            self.client.beginPairing(peripheral: device.id) { event in
                self.queue.async {
                    if case let .completed(bridgeId) = event {
                        if let previousBridge,
                           previousBridge != bridgeId { self.credentialStore.delete(bridgeId: previousBridge) }
                        self.mutate { st in
                            if st.bridgeId != bridgeId {
                                // A different bridge: nothing we knew about the old pump applies.
                                st.pumpSerial = nil
                                st.lastHistorySequence = nil
                                st.basalScheduleSynced = false
                                st.tempBasals = []
                            }
                            st.bridgeId = bridgeId
                            st.bridgeName = device.name
                            st.peripheralIdentifier = device.id.uuidString
                            st.pumpLink = .unknown
                        }
                        self.client.start(bridgeId: bridgeId, peripheral: device.id)
                        self.notifyStateDidChange()
                    }
                    DispatchQueue.main.async { handler(event) }
                }
            }
        }
    }

    func confirmPairingCode(matches: Bool) {
        client.confirmPairingCode(matches: matches)
    }

    func cancelPairing() {
        client.cancelPairing()
        queue.async {
            // Resume the previous session, if there was one.
            if let id = self.state.bridgeId, self.state.isOnboarded {
                self.client.start(bridgeId: id, peripheral: self.state.peripheralIdentifier.flatMap(UUID.init(uuidString:)))
            }
        }
    }

    // MARK: pump check

    /// Reads the pump status through the bridge (setup step 4). Fails with `notPaired` if the bridge has no pump.
    func checkPump(completion: @escaping (Result<BridgeStatus, BridgeError>) -> Void) {
        queue.async {
            self.commandQueue.enqueue("checkPump") { done in
                if let hello = self.client.hello, !hello.pumpPaired {
                    DispatchQueue.main.async {
                        completion(.failure(.remote(BridgeRemoteError(code: .notPaired, message: "", uncertain: false))))
                    }
                    done()
                    return
                }
                self.client.getStatus { result in
                    self.queue.async {
                        switch result {
                        case let .success(status):
                            self.applyStatus(status)
                            self.notifyStateDidChange()
                            let mapped: Result<BridgeStatus, BridgeError> = status.pumpLink == .notPaired
                                ? .failure(.remote(BridgeRemoteError(code: .notPaired, message: "", uncertain: false)))
                                : .success(status)
                            DispatchQueue.main.async { completion(mapped) }
                        case let .failure(error):
                            DispatchQueue.main.async { completion(.failure(error)) }
                        }
                        done()
                    }
                }
            }
        }
    }

    // MARK: finishing setup

    /// Setup step 5: sync time and the basal schedule, store limits, then mark the pump as set up.
    func finishSetup(
        basalItems: [RepeatingScheduleValue<Double>],
        maxBasal: Double?,
        maxBolus: Double?,
        insulinType: InsulinType?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            let s = self.state
            let converted: InsightBasalSchedule.Simplified
            do {
                converted = try InsightBasalSchedule.simplified(
                    items: basalItems,
                    minRate: s.limits.minBasal ?? InsightPumpSpec.minBasal,
                    maxRate: min(s.limits.maxBasal ?? InsightPumpSpec.maxBasalAbsolute, InsightPumpSpec.maxBasalAbsolute)
                )
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            self.mutate { st in
                st.insulinType = insulinType ?? st.insulinType
                st.maxBasal = [maxBasal, st.limits.maxBasal].compactMap { $0 }.min()
                st.maxBolus = [maxBolus, st.limits.maxBolus].compactMap { $0 }.min()
            }
            self.syncTime { timeResult in
                if case let .failure(error) = timeResult {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                self.pushBasalSchedule(converted.schedule) { result in
                    switch result {
                    case .success:
                        self.noteProfileConversion(converted)
                        self.queue.async {
                            self.mutate { $0.isOnboarded = true }
                            self.notifyStateDidChange()
                            DispatchQueue.main.async { completion(.success(())) }
                        }
                    case let .failure(error):
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            }
        }
    }

    // MARK: settings actions

    /// Re-sends the last requested basal schedule (e.g. after a failed or unconfirmed sync).
    func resyncBasalProfile(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let schedule = self.state.desiredBasalSchedule ?? self.state.basalSchedule else {
                DispatchQueue.main.async { completion(.failure(InsightPumpManagerError.noBasalSchedule)) }
                return
            }
            self.pushBasalSchedule(schedule, force: true) { result in
                DispatchQueue.main.async { completion(result.mapError { $0 as Error }) }
            }
        }
    }

    /// "Sync pump data": reads status and history. The result says whether the bridge could be reached.
    func refreshNow(completion: ((Result<Void, BridgeError>) -> Void)? = nil) {
        queue.async {
            self.client.ensureStarted()
            self.refreshAll(reason: "user") { result in
                DispatchQueue.main.async { completion?(result) }
            }
        }
    }

    func suspend(completion: @escaping (Error?) -> Void) {
        suspendDelivery { error in DispatchQueue.main.async { completion(error) } }
    }

    func resume(completion: @escaping (Error?) -> Void) {
        resumeDelivery { error in DispatchQueue.main.async { completion(error) } }
    }

    func setInsulinType(_ type: InsulinType) {
        queue.async {
            self.mutate { $0.insulinType = type }
            self.notifyStateDidChange()
        }
    }

    /// Forgets the pairing keys but keeps the pump record, so the user can pair the bridge again.
    func forgetBridgeKeys() {
        queue.async {
            self.client.stop()
            if let id = self.state.bridgeId { self.credentialStore.delete(bridgeId: id) }
            self.notifyStateDidChange()
        }
    }
}

public extension InsightPumpManager {
    /// The user left the setup flow before it finished: stop talking to the bridge and drop any stored key.
    func cancelSetup() {
        queue.async {
            guard !self.state.isOnboarded else { return }
            self.client.stopScan()
            self.client.cancelPairing()
            self.client.stop()
            if let id = self.state.bridgeId { self.credentialStore.delete(bridgeId: id) }
        }
    }
}

public extension InsightPumpManager {
    /// Cancels a running temporary basal (a zero-duration temp basal is LoopKit's way to say so).
    func stopTempBasal(completion: @escaping (Error?) -> Void) {
        enactTempBasal(decisionId: nil, unitsPerHour: 0, for: 0) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
