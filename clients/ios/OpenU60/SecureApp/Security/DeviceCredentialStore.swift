import CryptoKit
import Foundation
import Security

struct CredentialMetadata: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let secureEnclaveBacked: Bool

    init(id: String, label: String, secureEnclaveBacked: Bool) throws {
        guard id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              !label.isEmpty,
              label.count <= 64,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw LocalSecurityError.invalidPairingPayload
        }
        self.id = id
        self.label = label
        self.secureEnclaveBacked = secureEnclaveBacked
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            label: values.decode(String.self, forKey: .label),
            secureEnclaveBacked: values.decode(Bool.self, forKey: .secureEnclaveBacked)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case secureEnclaveBacked
    }
}

struct PendingCredential: Sendable {
    let publicKeySPKI: Data
    let secureEnclaveBacked: Bool
}

final class DeviceCredentialStore: @unchecked Sendable {
    private enum Account {
        static let privateKey = "signing-key"
        static let metadata = "credential-metadata"
        static let profile = "device-profile"
    }

    private let store: any SecretStore

    init(store: any SecretStore = KeychainStore(service: "com.lemoncandy42.u60.local-auth")) {
        self.store = store
    }

    func profile() throws -> DeviceProfile? {
        guard let data = try store.read(account: Account.profile) else { return nil }
        return try JSONDecoder().decode(DeviceProfile.self, from: data)
    }

    func metadata() throws -> CredentialMetadata? {
        guard let data = try store.read(account: Account.metadata) else { return nil }
        return try JSONDecoder().decode(CredentialMetadata.self, from: data)
    }

    func prepareCredential() throws -> PendingCredential {
        if let representation = try store.read(account: Account.privateKey) {
            return try pendingCredential(from: representation)
        }
        #if targetEnvironment(simulator)
            let key = P256.Signing.PrivateKey()
            try store.write(key.rawRepresentation, account: Account.privateKey)
            return PendingCredential(publicKeySPKI: key.publicKey.derRepresentation, secureEnclaveBacked: false)
        #else
            guard SecureEnclave.isAvailable,
                  let access = SecAccessControlCreateWithFlags(
                      nil,
                      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                      [.privateKeyUsage],
                      nil
                  )
            else {
                throw LocalSecurityError.unavailableSecureStorage
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try store.write(key.dataRepresentation, account: Account.privateKey)
            return PendingCredential(publicKeySPKI: key.publicKey.derRepresentation, secureEnclaveBacked: true)
        #endif
    }

    func commit(metadata: CredentialMetadata, profile: DeviceProfile) throws {
        let encoder = JSONEncoder()
        try store.write(encoder.encode(metadata), account: Account.metadata)
        do {
            try store.write(encoder.encode(profile), account: Account.profile)
        } catch {
            try? store.delete(account: Account.metadata)
            throw error
        }
    }

    func sign(_ message: Data) throws -> Data {
        guard let representation = try store.read(account: Account.privateKey) else {
            throw LocalSecurityError.missingCredential
        }
        #if targetEnvironment(simulator)
            let key = try P256.Signing.PrivateKey(rawRepresentation: representation)
            return try key.signature(for: message).derRepresentation
        #else
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
            return try key.signature(for: message).derRepresentation
        #endif
    }

    func removeLocalCredential() throws {
        var firstError: (any Error)?
        for account in [Account.metadata, Account.profile, Account.privateKey] {
            do {
                try store.delete(account: account)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func pendingCredential(from representation: Data) throws -> PendingCredential {
        #if targetEnvironment(simulator)
            let key = try P256.Signing.PrivateKey(rawRepresentation: representation)
            return PendingCredential(publicKeySPKI: key.publicKey.derRepresentation, secureEnclaveBacked: false)
        #else
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
            return PendingCredential(publicKeySPKI: key.publicKey.derRepresentation, secureEnclaveBacked: true)
        #endif
    }
}
