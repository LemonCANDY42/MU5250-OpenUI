import Foundation
import OpenAPIURLSession

enum AgentServiceError: LocalizedError {
    case rejected(status: Int, message: String)
    case invalidResponse
    case transportSecurity(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(status, message): "U60 rejected the request (\(status)): \(message)"
        case .invalidResponse: "The U60 returned a response that does not match the v1 contract."
        case let .transportSecurity(message): message
        }
    }
}

struct WifiTransactionEdits: Sendable {
    var ssid2g: String? = nil
    var passphrase2g: String? = nil
    var hidden2g: Bool? = nil
    var channel2g: String? = nil
    var bandwidth2g: String? = nil
    var transmitPower2g: Int? = nil
    var ssid5g: String? = nil
    var passphrase5g: String? = nil
    var hidden5g: Bool? = nil
    var channel5g: String? = nil
    var bandwidth5g: String? = nil
    var transmitPower5g: Int? = nil
    var guestEnabled2g: Bool? = nil
    var guestEnabled5g: Bool? = nil
    var guestSSID: String? = nil
    var guestPassphrase: String? = nil
    var guestHidden: Bool? = nil
    var guestIsolation: Bool? = nil
    var guestActiveTimeMinutes: Int? = nil
}

final class AgentService: Sendable {
    private let client: Client
    private let vault: SessionVault
    private let delegate: SPKIPinningDelegate

    init(profile: DeviceProfile, vault: SessionVault) throws {
        self.vault = vault
        let delegate = try SPKIPinningDelegate(expectedPin: profile.spkiSHA256)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let transport = URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
        client = Client(
            serverURL: profile.baseURL,
            transport: transport,
            middlewares: [BearerMiddleware(vault: vault)]
        )
    }

    func pair(nonce: String, label: String, publicKeySPKI: Data) async throws -> Components.Schemas.RegisteredCredential {
        delegate.resetTrustFailure()
        do {
            let output = try await client.registerCredential(.init(body: .json(.init(
                pairingNonce: nonce,
                label: label,
                publicKeySpki: Base64URL.encode(publicKeySPKI)
            ))))
            switch output {
            case let .ok(response): return try response.body.json.data
            default: throw AgentServiceError.invalidResponse
            }
        } catch {
            if let failure = delegate.consumeTrustFailure() {
                throw AgentServiceError.transportSecurity(failure.userMessage)
            }
            throw error
        }
    }

    func signIn(credentialID: String, signer: @Sendable (Data) throws -> Data) async throws {
        let challengeOutput = try await client.createCredentialChallenge(.init(body: .json(.init(
            credentialId: credentialID
        ))))
        let challenge: Components.Schemas.ChallengeGrant
        switch challengeOutput {
        case let .ok(response): challenge = try response.body.json.data
        default: throw AgentServiceError.invalidResponse
        }
        let message = try Base64URL.decode(challenge.message)
        let signature = try signer(message)
        let verifyOutput = try await client.verifyCredentialChallenge(.init(body: .json(.init(
            credentialId: credentialID,
            challengeId: challenge.challengeId,
            signature: Base64URL.encode(signature)
        ))))
        switch verifyOutput {
        case let .ok(response): try await vault.replace(with: response.body.json.data.token)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func signIn(password: String) async throws {
        let output = try await client.createPasswordSession(.init(body: .json(.init(password: password))))
        switch output {
        case let .ok(response): try await vault.replace(with: response.body.json.data.token)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func dashboard() async throws -> DashboardSnapshot {
        let reportOutput = try await client.getCapabilities()
        let report: Components.Schemas.CapabilityReport
        switch reportOutput {
        case let .ok(response): report = try response.body.json.data
        default: throw AgentServiceError.invalidResponse
        }

        var device: Components.Schemas.Device?
        var system: Components.Schemas.SystemStatus?
        var battery: Components.Schemas.BatteryStatus?
        var thermal: Components.Schemas.ThermalStatus?
        var signal: Components.Schemas.SignalStatus?
        var cellular: Components.Schemas.CellularStatus?
        var traffic: Components.Schemas.TrafficStatus?
        var wifi: Components.Schemas.WifiStatus?
        var lanClients: Components.Schemas.LanClients?
        var sms: Components.Schemas.SmsPage?
        var failures: [String: String] = [:]

        for capability in report.capabilities where capability.status != .unsupported {
            do {
                switch capability.id {
                case .deviceIdentity:
                    let output = try await client.getDevice()
                    if case let .ok(response) = output {
                        device = try response.body.json.data
                    } else {
                        failures["device_identity"] = "Unavailable"
                    }
                case .systemStatus:
                    let output = try await client.getSystemStatus()
                    if case let .ok(response) = output {
                        system = try response.body.json.data
                    } else {
                        failures["system_status"] = "Unavailable"
                    }
                case .batteryStatus:
                    let output = try await client.getBatteryStatus()
                    if case let .ok(response) = output {
                        battery = try response.body.json.data
                    } else {
                        failures["battery_status"] = "Unavailable"
                    }
                case .thermalStatus:
                    let output = try await client.getThermalStatus()
                    if case let .ok(response) = output {
                        thermal = try response.body.json.data
                    } else {
                        failures["thermal_status"] = "Unavailable"
                    }
                case .signalStatus:
                    let output = try await client.getSignalStatus()
                    if case let .ok(response) = output {
                        signal = try response.body.json.data
                    } else {
                        failures["signal_status"] = "Unavailable"
                    }
                case .cellularStatus:
                    let output = try await client.getCellularStatus()
                    if case let .ok(response) = output {
                        cellular = try response.body.json.data
                    } else {
                        failures["cellular_status"] = "Unavailable"
                    }
                case .trafficStatus:
                    let output = try await client.getTrafficStatus()
                    if case let .ok(response) = output {
                        traffic = try response.body.json.data
                    } else {
                        failures["traffic_status"] = "Unavailable"
                    }
                case .wifiStatus:
                    let output = try await client.getWifiStatus()
                    if case let .ok(response) = output {
                        wifi = try response.body.json.data
                    } else {
                        failures["wifi_status"] = "Unavailable"
                    }
                case .lanClients:
                    let output = try await client.getLanClients()
                    if case let .ok(response) = output {
                        lanClients = try response.body.json.data
                    } else {
                        failures["lan_clients"] = "Unavailable"
                    }
                case .smsList:
                    let output = try await client.getSmsList()
                    if case let .ok(response) = output {
                        sms = try response.body.json.data
                    } else {
                        failures["sms_list"] = "Unavailable"
                    }
                }
            } catch {
                failures[String(describing: capability.id)] = error.localizedDescription
            }
        }
        return DashboardSnapshot(
            report: report,
            device: device,
            system: system,
            battery: battery,
            thermal: thermal,
            signal: signal,
            cellular: cellular,
            traffic: traffic,
            wifi: wifi,
            lanClients: lanClients,
            sms: sms,
            failures: failures
        )
    }

    func sendSMS(recipient: String, message: String) async throws {
        let output = try await client.sendSms(.init(body: .json(.init(
            recipient: recipient,
            message: message
        ))))
        guard case .ok = output else { throw AgentServiceError.invalidResponse }
    }

    func chargingStatus() async throws -> Components.Schemas.ChargingStatus {
        let output = try await client.getChargingStatus()
        switch output {
        case let .ok(response): return try response.body.json.data
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 503, message: body.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func updateChargingLimit(
        _ limitPercent: Int?
    ) async throws -> Components.Schemas.ChargingStatus {
        let output = try await client.updateCharging(.init(body: .json(.init(
            operation: limitPercent == nil ? .disableLimit : .setLimit,
            limitPercent: limitPercent
        ))))
        switch output {
        case let .ok(response): return try response.body.json.data
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 503, message: body.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func updateTrafficCycle(resetDay: Int, enabled: Bool) async throws {
        let output = try await client.updateTrafficCycle(.init(body: .json(.init(
            resetDay: resetDay,
            enabled: enabled
        ))))
        switch output {
        case .ok: return
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 503, message: body.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func beginWifiTransaction(
        _ edits: WifiTransactionEdits
    ) async throws -> Components.Schemas.WifiTransactionGrant {
        let output = try await client.beginWifiTransaction(.init(body: .json(.init(
            ssid2g: edits.ssid2g,
            passphrase2g: edits.passphrase2g,
            hidden2g: edits.hidden2g,
            channel2g: edits.channel2g,
            bandwidth2g: edits.bandwidth2g,
            transmitPower2g: edits.transmitPower2g,
            ssid5g: edits.ssid5g,
            passphrase5g: edits.passphrase5g,
            hidden5g: edits.hidden5g,
            channel5g: edits.channel5g,
            bandwidth5g: edits.bandwidth5g,
            transmitPower5g: edits.transmitPower5g,
            guestEnabled2g: edits.guestEnabled2g,
            guestEnabled5g: edits.guestEnabled5g,
            guestSsid: edits.guestSSID,
            guestPassphrase: edits.guestPassphrase,
            guestHidden: edits.guestHidden,
            guestIsolation: edits.guestIsolation,
            guestActiveTimeMinutes: edits.guestActiveTimeMinutes
        ))))
        switch output {
        case let .ok(response): return try response.body.json.data
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 503, message: body.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func confirmWifiTransaction(id: String) async throws {
        let output = try await client.confirmWifiTransaction(.init(body: .json(.init(
            transactionId: id
        ))))
        guard case .ok = output else { throw AgentServiceError.invalidResponse }
    }
}
