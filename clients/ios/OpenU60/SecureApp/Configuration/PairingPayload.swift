import Foundation

struct DeviceProfile: Codable, Equatable, Sendable {
    let baseURL: URL
    let spkiSHA256: String

    init(baseURL: URL, spkiSHA256: String) throws {
        guard baseURL.scheme == "https",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              [9443, 19443].contains(baseURL.port),
              ["u60.local", "192.168.0.1"].contains(baseURL.host?.lowercased())
        else {
            throw LocalSecurityError.unsupportedEndpoint
        }
        guard DeviceProfile.isValidPin(spkiSHA256) else {
            throw LocalSecurityError.invalidPin
        }
        self.baseURL = baseURL
        self.spkiSHA256 = spkiSHA256
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseURL: values.decode(URL.self, forKey: .baseURL),
            spkiSHA256: values.decode(String.self, forKey: .spkiSHA256)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case spkiSHA256
    }

    static func isValidPin(_ value: String) -> Bool {
        guard value.hasPrefix("sha256/") else { return false }
        let encoded = String(value.dropFirst("sha256/".count))
        guard encoded.count == 44, let decoded = Data(base64Encoded: encoded) else { return false }
        return decoded.count == 32
    }
}

struct PairingPayload: Codable, Equatable, Sendable {
    let version: Int
    let baseURL: URL
    let spkiSHA256: String
    let pairingNonce: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case baseURL = "base_url"
        case spkiSHA256 = "spki_sha256"
        case pairingNonce = "pairing_nonce"
        case expiresAt = "expires_at"
    }

    var profile: DeviceProfile {
        get throws { try DeviceProfile(baseURL: baseURL, spkiSHA256: spkiSHA256) }
    }

    static func decode(_ string: String, now: Date = .now) throws -> PairingPayload {
        guard let data = string.data(using: .utf8) else {
            throw LocalSecurityError.invalidPairingPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PairingPayload.self, from: data),
              payload.version == 1,
              payload.pairingNonce.count == 43,
              (try? Base64URL.decode(payload.pairingNonce).count) == 32,
              (try? payload.profile) != nil
        else {
            throw LocalSecurityError.invalidPairingPayload
        }
        guard payload.expiresAt > now, payload.expiresAt.timeIntervalSince(now) <= 5 * 60 else {
            throw LocalSecurityError.expiredPairingPayload
        }
        return payload
    }
}
