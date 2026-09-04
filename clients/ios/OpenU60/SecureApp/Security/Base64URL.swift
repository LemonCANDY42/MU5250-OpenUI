import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        else {
            throw LocalSecurityError.invalidBase64URL
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard) else {
            throw LocalSecurityError.invalidBase64URL
        }
        return data
    }
}

enum LocalSecurityError: LocalizedError, Equatable {
    case invalidBase64URL
    case invalidPairingPayload
    case expiredPairingPayload
    case unsupportedEndpoint
    case invalidPin
    case unavailableSecureStorage
    case missingCredential
    case untrustedServer
    case localNetworkAccessDenied
    case missingManagementPassword

    var errorDescription: String? {
        switch self {
        case .invalidBase64URL: "Invalid base64url value."
        case .invalidPairingPayload: "The pairing code is incomplete or invalid."
        case .expiredPairingPayload: "The pairing code has expired. Open a new USB maintenance pairing window."
        case .unsupportedEndpoint: "Only the fixed local HTTPS U60 endpoint and canary ports are accepted."
        case .invalidPin: "The U60 certificate fingerprint is invalid."
        case .unavailableSecureStorage: "This device cannot access its local signing key."
        case .missingCredential: "No paired device key is available."
        case .untrustedServer: "The server certificate is not trusted or does not match the paired U60."
        case .localNetworkAccessDenied: "Local Network permission is required to pair. Allow OpenU60 Dev when iOS asks, then try again."
        case .missingManagementPassword: "Enter the OpenU60 management password."
        }
    }
}
