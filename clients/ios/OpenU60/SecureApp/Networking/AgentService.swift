import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum AgentServiceError: LocalizedError {
    case rejected(status: Int, message: String, recoveryRequired: Bool = false)
    case authenticationRequired
    case devicePowerNotSubmitted
    case invalidResponse
    case transportSecurity(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(status, message, _): "U60 rejected the request (\(status)): \(message)"
        case .authenticationRequired: "The secure session expired."
        case .devicePowerNotSubmitted:
            String(localized: "The U60 was unreachable before the power action could be submitted. Nothing was retried.")
        case .invalidResponse: "The U60 returned a response that does not match the v1 contract."
        case let .transportSecurity(message): message
        }
    }

    var keepsWifiConfirmationPending: Bool {
        switch self {
        case let .rejected(status, _, recoveryRequired):
            status == 503 && recoveryRequired
        case .invalidResponse:
            true
        case .authenticationRequired, .devicePowerNotSubmitted, .transportSecurity:
            false
        }
    }

    var keepsPendingWifiTransactionAfterConfirmation: Bool {
        switch self {
        case let .rejected(status, _, recoveryRequired):
            switch status {
            case 400, 409: false
            case 503: recoveryRequired
            default: true
            }
        case .authenticationRequired, .devicePowerNotSubmitted, .invalidResponse, .transportSecurity:
            true
        }
    }

}

enum AgentClockStatus: Equatable, Sendable {
    case unsupported
    case trusted
    case waitingForSync

    var showsSyncNotice: Bool {
        self == .waitingForSync
    }
}

enum DevicePowerAction: Equatable, Sendable {
    case reboot
    case powerOff
}

enum DevicePowerRequestOutcome: Equatable, Sendable {
    case confirmedAccepted
    case submissionResultUnknown
}

enum DevicePowerTransportDisposition: Equatable, Sendable {
    case notSubmitted
    case submissionResultUnknown

    static func classify(_ error: any Error) -> Self? {
        var pending: [any Error] = [error]
        var bestMatch: Self?
        var inspectedCount = 0

        while !pending.isEmpty, inspectedCount < 8 {
            let current = pending.removeFirst()
            inspectedCount += 1

            if let clientError = current as? ClientError {
                pending.append(clientError.underlyingError)
            }

            let nsError = current as NSError
            if nsError.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: nsError.code) {
                case .notConnectedToInternet,
                     .cannotFindHost,
                     .cannotConnectToHost,
                     .dnsLookupFailed,
                     .internationalRoamingOff,
                     .callIsActive,
                     .dataNotAllowed,
                     .cannotLoadFromNetwork:
                    return .notSubmitted
                case .timedOut,
                     .networkConnectionLost,
                     .resourceUnavailable,
                     .backgroundSessionWasDisconnected:
                    bestMatch = .submissionResultUnknown
                default:
                    break
                }
            }

            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
                pending.append(underlyingError)
            }
        }

        return bestMatch
    }
}

struct WifiTransactionEdits: Sendable {
    var ssid2g: String? = nil
    var passphrase2g: String? = nil
    var hidden2g: Bool? = nil
    var mainEnabled2g: Bool? = nil
    var channel2g: String? = nil
    var bandwidth2g: String? = nil
    var transmitPower2g: Int? = nil
    var ssid5g: String? = nil
    var passphrase5g: String? = nil
    var hidden5g: Bool? = nil
    var mainEnabled5g: Bool? = nil
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
        configuration.httpMaximumConnectionsPerHost = 2
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
            case let .serviceUnavailable(response):
                throw AgentServiceError.rejected(
                    status: 503,
                    message: try response.body.json.error.message
                )
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
        case let .badRequest(response):
            throw AgentServiceError.rejected(status: 400, message: try response.body.json.error.message)
        case let .unauthorized(response):
            throw AgentServiceError.rejected(status: 401, message: try response.body.json.error.message)
        case let .tooManyRequests(response):
            throw AgentServiceError.rejected(status: 429, message: try response.body.json.error.message)
        case let .internalServerError(response):
            throw AgentServiceError.rejected(status: 500, message: try response.body.json.error.message)
        case let .serviceUnavailable(response):
            throw AgentServiceError.rejected(status: 503, message: try response.body.json.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func elevate(password: String) async throws {
        let output = try await client.createAdvancedSession(.init(body: .json(.init(password: password))))
        switch output {
        case let .ok(response): try await vault.replace(with: response.body.json.data.token)
        case let .badRequest(response):
            throw AgentServiceError.rejected(status: 400, message: try response.body.json.error.message)
        case let .unauthorized(response):
            throw AgentServiceError.rejected(status: 401, message: try response.body.json.error.message)
        case let .forbidden(response):
            throw AgentServiceError.rejected(status: 403, message: try response.body.json.error.message)
        case let .tooManyRequests(response):
            throw AgentServiceError.rejected(status: 429, message: try response.body.json.error.message)
        case let .internalServerError(response):
            throw AgentServiceError.rejected(status: 500, message: try response.body.json.error.message)
        case let .serviceUnavailable(response):
            throw AgentServiceError.rejected(status: 503, message: try response.body.json.error.message)
        default: throw AgentServiceError.invalidResponse
        }
    }

    func performDevicePowerAction(_ action: DevicePowerAction) async throws -> DevicePowerRequestOutcome {
        delegate.resetTrustFailure()
        do {
            switch action {
            case .reboot:
                let output = try await client.rebootDevice()
                switch output {
                case .ok: return .confirmedAccepted
                case .unauthorized: throw AgentServiceError.authenticationRequired
                case let .badRequest(response):
                    throw AgentServiceError.rejected(status: 400, message: try response.body.json.error.message)
                case let .forbidden(response):
                    throw AgentServiceError.rejected(status: 403, message: try response.body.json.error.message)
                case let .conflict(response):
                    throw AgentServiceError.rejected(status: 409, message: try response.body.json.error.message)
                case let .internalServerError(response):
                    throw AgentServiceError.rejected(status: 500, message: try response.body.json.error.message)
                case let .serviceUnavailable(response):
                    throw AgentServiceError.rejected(status: 503, message: try response.body.json.error.message)
                default: throw AgentServiceError.invalidResponse
                }
            case .powerOff:
                let output = try await client.powerOffDevice()
                switch output {
                case .ok: return .confirmedAccepted
                case .unauthorized: throw AgentServiceError.authenticationRequired
                case let .badRequest(response):
                    throw AgentServiceError.rejected(status: 400, message: try response.body.json.error.message)
                case let .forbidden(response):
                    throw AgentServiceError.rejected(status: 403, message: try response.body.json.error.message)
                case let .conflict(response):
                    throw AgentServiceError.rejected(status: 409, message: try response.body.json.error.message)
                case let .internalServerError(response):
                    throw AgentServiceError.rejected(status: 500, message: try response.body.json.error.message)
                case let .serviceUnavailable(response):
                    throw AgentServiceError.rejected(status: 503, message: try response.body.json.error.message)
                default: throw AgentServiceError.invalidResponse
                }
            }
        } catch {
            if let failure = delegate.consumeTrustFailure() {
                throw AgentServiceError.transportSecurity(failure.userMessage)
            }
            switch DevicePowerTransportDisposition.classify(error) {
            case .notSubmitted:
                throw AgentServiceError.devicePowerNotSubmitted
            case .submissionResultUnknown:
                return .submissionResultUnknown
            case nil:
                break
            }
            throw error
        }
    }

    func dashboard() async throws -> DashboardSnapshot {
        let output = try await client.getDashboardSnapshot()
        let aggregate: Components.Schemas.DashboardSnapshot
        switch output {
        case let .ok(response):
            do {
                aggregate = try response.body.json.data
            } catch {
                throw AgentServiceError.invalidResponse
            }
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .forbidden(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 403, message: body.error.message)
        case let .internalServerError(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 500, message: body.error.message)
        default: throw AgentServiceError.invalidResponse
        }
        let failures = aggregate.failures.reduce(into: [String: String]()) { result, failure in
            if result[failure.component.rawValue] == nil {
                result[failure.component.rawValue] = failure.error.message
            }
        }
        return DashboardSnapshot(
            report: aggregate.report,
            device: aggregate.device,
            system: aggregate.system,
            battery: aggregate.battery,
            thermal: aggregate.thermal,
            signal: aggregate.signal,
            cellular: aggregate.cellular,
            traffic: aggregate.traffic,
            wifi: aggregate.wifi,
            lanClients: aggregate.lanClients,
            sms: aggregate.sms,
            charging: aggregate.charging,
            failures: failures
        )
    }

    func clockStatus() async throws -> AgentClockStatus {
        let output = try await client.getClockStatus()
        switch output {
        case let .ok(response):
            switch try response.body.json.data.state {
            case .trusted: return .trusted
            case .waitingForSync: return .waitingForSync
            }
        case .notFound:
            return .unsupported
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .forbidden(response):
            throw AgentServiceError.rejected(
                status: 403,
                message: try response.body.json.error.message
            )
        case let .internalServerError(response):
            throw AgentServiceError.rejected(
                status: 500,
                message: try response.body.json.error.message
            )
        default:
            throw AgentServiceError.invalidResponse
        }
    }

    func sendSMS(recipient: String, message: String) async throws {
        let output = try await client.sendSms(.init(body: .json(.init(
            recipient: recipient,
            message: message
        ))))
        switch output {
        case .ok: return
        case .unauthorized: throw AgentServiceError.authenticationRequired
        case let .serviceUnavailable(response):
            throw AgentServiceError.rejected(
                status: 503,
                message: try response.body.json.error.message,
                recoveryRequired: try response.body.json.error.recovery.required
            )
        default: throw AgentServiceError.invalidResponse
        }
    }

    func chargingStatus() async throws -> Components.Schemas.ChargingStatus {
        let output = try await client.getChargingStatus()
        switch output {
        case let .ok(response): return try response.body.json.data
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 503,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
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
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 503,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
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
            mainEnabled2g: edits.mainEnabled2g,
            channel2g: edits.channel2g,
            bandwidth2g: edits.bandwidth2g,
            transmitPower2g: edits.transmitPower2g,
            ssid5g: edits.ssid5g,
            passphrase5g: edits.passphrase5g,
            hidden5g: edits.hidden5g,
            mainEnabled5g: edits.mainEnabled5g,
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
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .conflict(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 409,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 503,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
        default: throw AgentServiceError.invalidResponse
        }
    }

    func confirmWifiTransaction(id: String) async throws {
        let output = try await client.confirmWifiTransaction(.init(body: .json(.init(
            transactionId: id
        ))))
        switch output {
        case .ok: return
        case .unauthorized:
            throw AgentServiceError.authenticationRequired
        case let .badRequest(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(status: 400, message: body.error.message)
        case let .conflict(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 409,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
        case let .serviceUnavailable(response):
            let body = try response.body.json
            throw AgentServiceError.rejected(
                status: 503,
                message: body.error.message,
                recoveryRequired: body.error.recovery.required
            )
        default: throw AgentServiceError.invalidResponse
        }
    }
}
