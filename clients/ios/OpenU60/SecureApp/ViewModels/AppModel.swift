import Foundation
import Observation

struct PendingWifiConfirmation: Codable, Equatable {
    static let confirmationWindow: TimeInterval = 120

    let transactionId: String
    let expiresAt: Date

    static func make(now: Date = .now) -> Self {
        let identifier = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        return Self(
            transactionId: identifier,
            expiresAt: now.addingTimeInterval(confirmationWindow)
        )
    }
}

@MainActor
@Observable
final class AppModel {
    struct Notice: Equatable {
        let title: String
        let message: String
    }

    enum Phase: Equatable {
        case booting
        case needsPairing
        case signedOut
        case authenticated
    }

    private(set) var phase: Phase = .booting
    private(set) var dashboard: DashboardSnapshot?
    private(set) var profile: DeviceProfile?
    private(set) var credential: CredentialMetadata?
    private(set) var charging: Components.Schemas.ChargingStatus?
    private(set) var telemetryHistory: [TelemetrySample]
    private(set) var pendingWifiConfirmation: PendingWifiConfirmation?
    private(set) var wifiConfirmationMessage: String?
    private(set) var isConfirmingWifi = false
    private(set) var isWorking = false
    private(set) var notice: Notice?
    private(set) var connectionIssue: ConnectionIssue?
    var errorMessage: String?

    private let credentials: DeviceCredentialStore
    private let vault: SessionVault
    private let wifiConfirmations: WifiConfirmationStore
    private let telemetryHistoryStore: TelemetryHistoryStore
    private var service: AgentService?
    @ObservationIgnored private var wifiConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var connectionRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var connectionRecoveryGeneration = 0
    @ObservationIgnored private var appIsActive = true

    init(
        credentials: DeviceCredentialStore = DeviceCredentialStore(),
        vault: SessionVault = SessionVault(),
        wifiConfirmations: WifiConfirmationStore = WifiConfirmationStore(),
        telemetryHistoryStore: TelemetryHistoryStore = TelemetryHistoryStore()
    ) {
        self.credentials = credentials
        self.vault = vault
        self.wifiConfirmations = wifiConfirmations
        self.telemetryHistoryStore = telemetryHistoryStore
        telemetryHistory = telemetryHistoryStore.load()
        if let pending = try? wifiConfirmations.load() {
            pendingWifiConfirmation = pending
        }
    }

    func boot() async {
        do {
            profile = try credentials.profile()
            credential = try credentials.metadata()
            guard let profile, let credential else {
                phase = .needsPairing
                return
            }
            service = try AgentService(profile: profile, vault: vault)
            phase = .signedOut
            await signInWithDeviceKey(credential: credential)
        } catch {
            phase = .needsPairing
            errorMessage = error.localizedDescription
        }
    }

    func pair(payloadText: String, label: String) async {
        await perform {
            let payload = try PairingPayload.decode(payloadText)
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedLabel.isEmpty, normalizedLabel.count <= 64 else {
                throw LocalSecurityError.invalidPairingPayload
            }
            let profile = try payload.profile
            try await LocalNetworkPreflight.requestAccess(for: profile)
            let pending = try credentials.prepareCredential()
            let pairingService = try AgentService(profile: profile, vault: vault)
            let registered = try await pairingService.pair(
                nonce: payload.pairingNonce,
                label: normalizedLabel,
                publicKeySPKI: pending.publicKeySPKI
            )
            let metadata = try CredentialMetadata(
                id: registered.id,
                label: registered.label,
                secureEnclaveBacked: pending.secureEnclaveBacked
            )
            do {
                try credentials.commit(metadata: metadata, profile: profile)
            } catch {
                throw PairingCommitError.registeredButNotStored
            }
            self.profile = profile
            self.credential = metadata
            self.service = pairingService
            self.phase = .signedOut
            try await self.signInWithDeviceKeyThrowing(credential: metadata)
        }
    }

    func signInWithDeviceKey() async {
        guard let credential else {
            errorMessage = LocalSecurityError.missingCredential.localizedDescription
            return
        }
        await signInWithDeviceKey(credential: credential)
    }

    func signInWithPassword(_ password: String) async {
        await perform {
            guard !password.isEmpty, let service else {
                throw LocalSecurityError.invalidPairingPayload
            }
            try await service.signIn(password: password)
            phase = .authenticated
            try await refreshThrowing()
        }
    }

    func refresh() async {
        guard !isWorking else { return }
        notice = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await refreshThrowing()
        } catch {
            handleReadFailure(error)
        }
    }

    func sendSMS(recipient: String, message: String) async {
        await perform {
            guard let service else { throw LocalSecurityError.missingCredential }
            try await service.sendSMS(recipient: recipient, message: message)
            try await refreshThrowing()
        }
    }

    func setTrafficCycle(day: Int, enabled: Bool) async {
        await perform {
            guard let service else { throw LocalSecurityError.missingCredential }
            try await service.updateTrafficCycle(resetDay: day, enabled: enabled)
            try await refreshThrowing()
        }
    }

    func beginWifiTransaction(_ edits: WifiTransactionEdits) async {
        guard !isWorking else { return }
        guard pendingWifiConfirmation == nil else {
            errorMessage = String(localized: "Finish or wait for the current Wi-Fi verification before applying another change.")
            return
        }
        guard let service else {
            errorMessage = LocalSecurityError.missingCredential.localizedDescription
            return
        }

        notice = nil
        errorMessage = nil
        isWorking = true
        let pending = PendingWifiConfirmation.make()
        do {
            try storePendingWifiConfirmation(pending)
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
            return
        }
        wifiConfirmationMessage = String(localized: "Waiting to reconnect. You can switch networks more than once; verification continues until the deadline.")

        do {
            let grant = try await service.beginWifiTransaction(edits, transactionID: pending.transactionId)
            guard grant.transactionId == pending.transactionId else {
                throw AgentServiceError.invalidResponse
            }
        } catch let error as AgentServiceError {
            if case .rejected(status: 400, _) = error {
                clearPendingWifiConfirmation(cancelTask: false)
            }
            errorMessage = error.localizedDescription
        } catch {
            // Losing the response while Wi-Fi restarts is ambiguous. Keep the
            // client-generated identifier and continue safe confirmation probes.
        }
        isWorking = false
        startWifiConfirmationLoop()
    }

    func confirmWifiTransaction() async {
        _ = await attemptWifiConfirmation(showFailure: true)
    }

    func resumeWifiConfirmation() {
        if pendingWifiConfirmation == nil,
           let restored = try? wifiConfirmations.load()
        {
            pendingWifiConfirmation = restored
        }
        guard phase == .authenticated, pendingWifiConfirmation != nil else { return }
        startWifiConfirmationLoop()
    }

    func setAppActive(_ isActive: Bool) {
        appIsActive = isActive
        if isActive {
            resumeWifiConfirmation()
            if connectionIssue != nil {
                startConnectionRecoveryLoop(retryImmediately: true)
            }
        } else {
            cancelConnectionRecovery()
        }
    }

    func dismissPresentedMessage() {
        errorMessage = nil
        notice = nil
    }

    func signOut() async {
        cancelConnectionRecovery()
        connectionIssue = nil
        wifiConfirmationTask?.cancel()
        wifiConfirmationTask = nil
        await vault.clear()
        dashboard = nil
        charging = nil
        notice = nil
        phase = profile == nil ? .needsPairing : .signedOut
    }

    func discardLocalPairing() async {
        do {
            cancelConnectionRecovery()
            connectionIssue = nil
            try credentials.removeLocalCredential()
            await vault.clear()
            dashboard = nil
            charging = nil
            clearPendingWifiConfirmation(cancelTask: true)
            notice = nil
            profile = nil
            credential = nil
            service = nil
            phase = .needsPairing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signInWithDeviceKey(credential: CredentialMetadata) async {
        guard !isWorking else { return }
        notice = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await signInWithDeviceKeyThrowing(credential: credential)
        } catch {
            if phase == .booting {
                phase = profile == nil ? .needsPairing : .signedOut
            }
            handleReadFailure(error)
        }
    }

    private func signInWithDeviceKeyThrowing(credential: CredentialMetadata) async throws {
        guard let service else { throw LocalSecurityError.missingCredential }
        try await service.signIn(credentialID: credential.id) { message in
            try self.credentials.sign(message)
        }
        phase = .authenticated
        try await refreshThrowing()
        resumeWifiConfirmation()
    }

    private func refreshThrowing() async throws {
        guard let service else { throw LocalSecurityError.missingCredential }
        let result = try await loadDashboard(using: service)
        applyDashboard(result.snapshot, charging: result.charging)
    }

    private func loadDashboard(
        using service: AgentService
    ) async throws -> (snapshot: DashboardSnapshot, charging: Components.Schemas.ChargingStatus?) {
        let snapshot = try await service.dashboard()
        let charging = try? await service.chargingStatus()
        return (snapshot, charging)
    }

    private func applyDashboard(
        _ snapshot: DashboardSnapshot,
        charging newCharging: Components.Schemas.ChargingStatus?
    ) {
        dashboard = snapshot
        charging = newCharging
        telemetryHistory = telemetryHistoryStore.append(
            TelemetrySample(
                timestamp: .now,
                batteryPercent: snapshot.battery?.capacityPercent,
                lteRSRPdBm: snapshot.signal?.lte?.rsrpDbm.map(Double.init),
                nr5gRSRPdBm: snapshot.signal?.nr5g?.rsrpDbm.map(Double.init),
                wifiSignalDbm: snapshot.wifi?.currentClientLink.map { Double($0.signalDbm) },
                thermalTemperaturesC: snapshot.thermal?.sensors.reduce(into: [:]) { temperatures, sensor in
                    temperatures[sensor.sensor] = sensor.temperatureC
                } ?? [:],
                cpuUsagePercent: snapshot.system?.cpuUsagePercent,
                memoryUsedPercent: snapshot.system?.memoryUsedPercent,
                storageUsedPercent: snapshot.system?.storageUsedPercent
            ),
            to: telemetryHistory
        )
        clearConnectionIssue()
    }

    private func handleReadFailure(_ error: any Error) {
        guard !Task.isCancelled else { return }
        guard let issue = ConnectionIssue.classify(error) else {
            errorMessage = error.localizedDescription
            return
        }
        connectionIssue = issue
        startConnectionRecoveryLoop(retryImmediately: false)
    }

    private func startConnectionRecoveryLoop(retryImmediately: Bool) {
        guard appIsActive,
              connectionIssue != nil,
              phase == .signedOut || phase == .authenticated,
              connectionRecoveryTask == nil
        else { return }

        connectionRecoveryGeneration += 1
        let generation = connectionRecoveryGeneration
        connectionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionRecoveryGeneration == generation {
                    self.connectionRecoveryTask = nil
                }
            }

            let delays: [Duration] = [.seconds(3), .seconds(5), .seconds(10), .seconds(15), .seconds(30)]
            var attempt = 0
            if !retryImmediately {
                try? await Task.sleep(for: delays[0])
            }

            while !Task.isCancelled,
                  self.appIsActive,
                  self.connectionIssue != nil
            {
                if self.isWorking {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                self.isWorking = true
                do {
                    guard let profile = self.profile else {
                        throw LocalSecurityError.missingCredential
                    }
                    let recoveryService = try AgentService(profile: profile, vault: self.vault)
                    if self.phase == .signedOut {
                        guard let credential = self.credential else {
                            throw LocalSecurityError.missingCredential
                        }
                        try await recoveryService.signIn(credentialID: credential.id) { message in
                            try self.credentials.sign(message)
                        }
                    }
                    let result = try await self.loadDashboard(using: recoveryService)
                    guard !Task.isCancelled,
                          self.connectionRecoveryGeneration == generation
                    else {
                        self.isWorking = false
                        return
                    }
                    self.isWorking = false
                    self.service = recoveryService
                    self.phase = .authenticated
                    self.applyDashboard(result.snapshot, charging: result.charging)
                    self.resumeWifiConfirmation()
                    return
                } catch {
                    self.isWorking = false
                    guard !Task.isCancelled,
                          self.connectionRecoveryGeneration == generation
                    else { return }
                    guard let issue = ConnectionIssue.classify(error) else {
                        self.connectionIssue = nil
                        self.errorMessage = error.localizedDescription
                        return
                    }
                    self.connectionIssue = issue
                }

                let delay = delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func clearConnectionIssue() {
        connectionIssue = nil
        cancelConnectionRecovery()
    }

    private func cancelConnectionRecovery() {
        connectionRecoveryGeneration += 1
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
    }

    private func startWifiConfirmationLoop() {
        wifiConfirmationTask?.cancel()
        wifiConfirmationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let pending = self.pendingWifiConfirmation {
                if Date.now >= pending.expiresAt {
                    self.finishExpiredWifiConfirmation()
                    return
                }
                if await self.attemptWifiConfirmation(showFailure: false) {
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func attemptWifiConfirmation(showFailure: Bool) async -> Bool {
        guard !isConfirmingWifi,
              phase == .authenticated,
              let profile,
              let pending = pendingWifiConfirmation
        else { return false }
        guard Date.now < pending.expiresAt else {
            finishExpiredWifiConfirmation()
            return false
        }

        isConfirmingWifi = true
        defer { isConfirmingWifi = false }
        do {
            // A fresh pinned session proves the U60 is reachable on the current
            // network path instead of reusing a pre-reload HTTP connection.
            let confirmationService = try AgentService(profile: profile, vault: vault)
            try await confirmationService.confirmWifiTransaction(id: pending.transactionId)
            guard pendingWifiConfirmation?.transactionId == pending.transactionId else { return false }
            clearPendingWifiConfirmation(cancelTask: false)
            notice = Notice(
                title: String(localized: "Wi-Fi updated"),
                message: String(localized: "Reconnected to the U60. The new Wi-Fi settings were verified and automatic rollback was cancelled.")
            )
            try? await refreshThrowing()
            return true
        } catch {
            wifiConfirmationMessage = String(localized: "Not verified yet. The app will keep checking while the rollback window remains open.")
            if showFailure {
                errorMessage = String(localized: "The U60 is not reachable with the requested settings yet. You can change networks again; automatic verification will continue.")
            }
            return false
        }
    }

    private func finishExpiredWifiConfirmation() {
        guard pendingWifiConfirmation != nil else { return }
        clearPendingWifiConfirmation(cancelTask: false)
        notice = Notice(
            title: String(localized: "Wi-Fi verification ended"),
            message: String(localized: "No verified reconnection was received before the deadline. The independent U60 rollback process restores the previous settings; reconnect to the previous network and refresh.")
        )
    }

    private func storePendingWifiConfirmation(_ pending: PendingWifiConfirmation) throws {
        try wifiConfirmations.save(pending)
        pendingWifiConfirmation = pending
    }

    private func clearPendingWifiConfirmation(cancelTask: Bool) {
        if cancelTask {
            wifiConfirmationTask?.cancel()
            wifiConfirmationTask = nil
        }
        pendingWifiConfirmation = nil
        wifiConfirmationMessage = nil
        try? wifiConfirmations.clear()
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        notice = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            if phase == .booting {
                phase = profile == nil ? .needsPairing : .signedOut
            }
            errorMessage = error.localizedDescription
        }
    }
}

enum PairingCommitError: LocalizedError {
    case registeredButNotStored

    var errorDescription: String? {
        "The key was registered by the U60 but could not be stored locally. Revoke that credential through USB maintenance before retrying."
    }
}
