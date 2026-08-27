import Foundation
import OpenAPIRuntime
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

private enum DashboardCapabilityResult: Sendable {
    case device(Components.Schemas.Device)
    case system(Components.Schemas.SystemStatus)
    case battery(Components.Schemas.BatteryStatus)
    case thermal(Components.Schemas.ThermalStatus)
    case signal(Components.Schemas.SignalStatus)
    case cellular(Components.Schemas.CellularStatus)
    case traffic(Components.Schemas.TrafficStatus)
    case wifi(Components.Schemas.WifiStatus)
    case lanClients(Components.Schemas.LanClients)
    case sms(Components.Schemas.SmsPage)
    case failure(key: String, message: String)
}

enum DashboardRequestScheduler {
    static let maximumConcurrentRequests = 10

    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        operation: @Sendable @escaping (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: Output.self) { group in
            var iterator = inputs.makeIterator()
            let initialCount = min(maximumConcurrentRequests, inputs.count)
            for _ in 0 ..< initialCount {
                guard let input = iterator.next() else { break }
                group.addTask {
                    try Task.checkCancellation()
                    return try await operation(input)
                }
            }

            var results: [Output] = []
            while let result = try await group.next() {
                results.append(result)
                if let input = iterator.next() {
                    group.addTask {
                        try Task.checkCancellation()
                        return try await operation(input)
                    }
                }
            }
            return results
        }
    }
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
        configuration.httpMaximumConnectionsPerHost = DashboardRequestScheduler.maximumConcurrentRequests
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

        let capabilityIDs = Self.dashboardCapabilityIDs(from: report.capabilities)
        let results = try await DashboardRequestScheduler.run(capabilityIDs) { [self] capability in
            try await fetchDashboardCapability(capability)
        }

        for result in results {
            switch result {
            case let .device(value): device = value
            case let .system(value): system = value
            case let .battery(value): battery = value
            case let .thermal(value): thermal = value
            case let .signal(value): signal = value
            case let .cellular(value): cellular = value
            case let .traffic(value): traffic = value
            case let .wifi(value): wifi = value
            case let .lanClients(value): lanClients = value
            case let .sms(value): sms = value
            case let .failure(key, message): failures[key] = message
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

    static func dashboardCapabilityIDs(
        from capabilities: [Components.Schemas.Capability]
    ) -> [Components.Schemas.Capability.IdPayload] {
        var seen = Set<String>()
        return capabilities.compactMap { capability in
            guard capability.status != .unsupported,
                  seen.insert(capability.id.rawValue).inserted
            else { return nil }
            return capability.id
        }
    }

    private func fetchDashboardCapability(
        _ capability: Components.Schemas.Capability.IdPayload
    ) async throws -> DashboardCapabilityResult {
        do {
            switch capability {
            case .deviceIdentity:
                let output = try await client.getDevice()
                if case let .ok(response) = output {
                    return .device(try response.body.json.data)
                }
            case .systemStatus:
                let output = try await client.getSystemStatus()
                if case let .ok(response) = output {
                    return .system(try response.body.json.data)
                }
            case .batteryStatus:
                let output = try await client.getBatteryStatus()
                if case let .ok(response) = output {
                    return .battery(try response.body.json.data)
                }
            case .thermalStatus:
                let output = try await client.getThermalStatus()
                if case let .ok(response) = output {
                    return .thermal(try response.body.json.data)
                }
            case .signalStatus:
                let output = try await client.getSignalStatus()
                if case let .ok(response) = output {
                    return .signal(try response.body.json.data)
                }
            case .cellularStatus:
                let output = try await client.getCellularStatus()
                if case let .ok(response) = output {
                    return .cellular(try response.body.json.data)
                }
            case .trafficStatus:
                let output = try await client.getTrafficStatus()
                if case let .ok(response) = output {
                    return .traffic(try response.body.json.data)
                }
            case .wifiStatus:
                let output = try await client.getWifiStatus()
                if case let .ok(response) = output {
                    return .wifi(try response.body.json.data)
                }
            case .lanClients:
                let output = try await client.getLanClients()
                if case let .ok(response) = output {
                    return .lanClients(try response.body.json.data)
                }
            case .smsList:
                let output = try await client.getSmsList()
                if case let .ok(response) = output {
                    return .sms(try response.body.json.data)
                }
            }
            return .failure(
                key: dashboardFailureKey(for: capability),
                message: String(localized: "Unavailable")
            )
        } catch {
            try Task.checkCancellation()
            return .failure(
                key: dashboardFailureKey(for: capability),
                message: Self.dashboardFailureMessage(for: capability, error: error)
            )
        }
    }

    private func dashboardFailureKey(for capability: Components.Schemas.Capability.IdPayload) -> String {
        switch capability {
        case .deviceIdentity: "device_identity"
        case .systemStatus: "system_status"
        case .batteryStatus: "battery_status"
        case .thermalStatus: "thermal_status"
        case .signalStatus: "signal_status"
        case .cellularStatus: "cellular_status"
        case .trafficStatus: "traffic_status"
        case .wifiStatus: "wifi_status"
        case .lanClients: "lan_clients"
        case .smsList: "sms_list"
        }
    }

    static func dashboardFailureMessage(
        for capability: Components.Schemas.Capability.IdPayload,
        error: any Error
    ) -> String {
        let decodingError: DecodingError? = if let clientError = error as? ClientError {
            clientError.underlyingError as? DecodingError
        } else {
            error as? DecodingError
        }

        if case .wifiStatus = capability,
           let decodingError,
           case DecodingError.keyNotFound(let key, _) = decodingError,
           key.stringValue == "features"
        {
            return String(
                localized: "The running agent does not provide the required Wi-Fi feature fields. Update it to the same release as this app."
            )
        }
        return error.localizedDescription
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
        _ edits: WifiTransactionEdits,
        transactionID: String
    ) async throws -> Components.Schemas.WifiTransactionGrant {
        let output = try await client.beginWifiTransaction(.init(body: .json(.init(
            transactionId: transactionID,
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
}
