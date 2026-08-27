import Foundation
import Observation

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
    private(set) var pendingWifiTransaction: Components.Schemas.WifiTransactionGrant?
    private(set) var isWorking = false
    private(set) var notice: Notice?
    var errorMessage: String?

    private let credentials: DeviceCredentialStore
    private let vault: SessionVault
    private var service: AgentService?

    init(
        credentials: DeviceCredentialStore = DeviceCredentialStore(),
        vault: SessionVault = SessionVault()
    ) {
        self.credentials = credentials
        self.vault = vault
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
        await perform { try await refreshThrowing() }
    }

    func sendSMS(recipient: String, message: String) async {
        await perform {
            guard let service else { throw LocalSecurityError.missingCredential }
            try await service.sendSMS(recipient: recipient, message: message)
            try await refreshThrowing()
        }
    }

    func setChargingLimit(_ limit: Int?) async {
        await perform {
            guard let service else { throw LocalSecurityError.missingCredential }
            charging = try await service.updateChargingLimit(limit)
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
        await perform {
            guard let service else { throw LocalSecurityError.missingCredential }
            pendingWifiTransaction = try await service.beginWifiTransaction(edits)
        }
    }

    func confirmWifiTransaction() async {
        await perform {
            guard let service, let pendingWifiTransaction else {
                throw LocalSecurityError.invalidPairingPayload
            }
            try await service.confirmWifiTransaction(id: pendingWifiTransaction.transactionId)
            self.pendingWifiTransaction = nil
            try await refreshThrowing()
            notice = Notice(
                title: String(localized: "Wi-Fi updated"),
                message: String(localized: "Reconnected to the U60. The new Wi-Fi settings were verified and automatic rollback was cancelled.")
            )
        }
    }

    func dismissPresentedMessage() {
        errorMessage = nil
        notice = nil
    }

    func signOut() async {
        await vault.clear()
        dashboard = nil
        charging = nil
        pendingWifiTransaction = nil
        notice = nil
        phase = profile == nil ? .needsPairing : .signedOut
    }

    func discardLocalPairing() async {
        do {
            try credentials.removeLocalCredential()
            await vault.clear()
            dashboard = nil
            charging = nil
            pendingWifiTransaction = nil
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
        await perform {
            try await signInWithDeviceKeyThrowing(credential: credential)
        }
    }

    private func signInWithDeviceKeyThrowing(credential: CredentialMetadata) async throws {
        guard let service else { throw LocalSecurityError.missingCredential }
        try await service.signIn(credentialID: credential.id) { message in
            try self.credentials.sign(message)
        }
        phase = .authenticated
        try await refreshThrowing()
    }

    private func refreshThrowing() async throws {
        guard let service else { throw LocalSecurityError.missingCredential }
        dashboard = try await service.dashboard()
        charging = try? await service.chargingStatus()
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
