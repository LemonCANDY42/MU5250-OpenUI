import CryptoKit
import Foundation
@testable import OpenU60
import Security
import XCTest

final class SecurityContractTests: XCTestCase {
    func testBase64URLRoundTrip() throws {
        let data = Data(0 ..< 32)
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(try Base64URL.decode(encoded), data)
        XCTAssertThrowsError(try Base64URL.decode("not+url"))
    }

    func testPairingPayloadRequiresFreshFixedLocalHTTPSProfile() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nonce = Base64URL.encode(Data(repeating: 7, count: 32))
        let pin = "sha256/" + Data(repeating: 9, count: 32).base64EncodedString()
        let valid = payloadJSON(
            baseURL: "https://u60.local:19443",
            pin: pin,
            nonce: nonce,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(try PairingPayload.decode(valid, now: now).profile.spkiSHA256, pin)

        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "http://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(120)),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://example.com:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(120)),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(301)),
            now: now
        ))
    }

    func testLocalNetworkPreflightUsesOnlyTheValidatedPairingEndpoint() throws {
        let profile = try DeviceProfile(
            baseURL: XCTUnwrap(URL(string: "https://192.168.0.1:9443")),
            spkiSHA256: "sha256/" + Data(repeating: 9, count: 32).base64EncodedString()
        )

        XCTAssertEqual(
            try LocalNetworkPreflight.endpoint(for: profile),
            .init(host: "192.168.0.1", port: 9443)
        )
    }

    func testSimulatorCredentialSignsAndPersistsOnlyDeviceLocalMaterial() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        let pending = try credentials.prepareCredential()
        #if targetEnvironment(simulator)
            XCTAssertFalse(pending.secureEnclaveBacked)
        #endif
        let message = Data("u60-test-challenge".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: credentials.sign(message))
        let publicKey = try P256.Signing.PublicKey(derRepresentation: pending.publicKeySPKI)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))

        let profile = try DeviceProfile(
            baseURL: XCTUnwrap(URL(string: "https://u60.local:19443")),
            spkiSHA256: "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        )
        let metadata = try CredentialMetadata(id: "credential_1", label: "Test", secureEnclaveBacked: false)
        try credentials.commit(metadata: metadata, profile: profile)
        XCTAssertEqual(try credentials.metadata(), metadata)
        XCTAssertEqual(try credentials.profile(), profile)
        try credentials.removeLocalCredential()
        XCTAssertNil(try credentials.metadata())
        XCTAssertNil(try credentials.profile())
    }

    func testP256SPKIPinMatchesCryptoKitDER() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        let secKey = try XCTUnwrap(SecKeyCreateWithData(publicKey.x963Representation as CFData, attributes as CFDictionary, &error))
        let expected = "sha256/" + Data(SHA256.hash(data: publicKey.derRepresentation)).base64EncodedString()
        XCTAssertEqual(SPKIPinningDelegate.pin(for: secKey), expected)
    }

    func testPersistedProfileAndCredentialAreRevalidatedOnRead() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        try memory.write(
            Data(#"{"baseURL":"https://example.com:9443","spkiSHA256":"sha256/BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ="}"#.utf8),
            account: "device-profile"
        )
        XCTAssertThrowsError(try credentials.profile())

        try memory.write(
            Data(#"{"id":"../../bad","label":"Test","secureEnclaveBacked":false}"#.utf8),
            account: "credential-metadata"
        )
        XCTAssertThrowsError(try credentials.metadata())
    }

    func testInvalidPersistedSigningKeyCanBeDiscardedAndRecreated() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        try memory.write(Data(repeating: 0xFF, count: 19), account: "signing-key")
        XCTAssertThrowsError(try credentials.prepareCredential())

        try credentials.removeLocalCredential()
        let replacement = try credentials.prepareCredential()
        XCTAssertFalse(replacement.publicKeySPKI.isEmpty)
    }

    func testAllHTTPRedirectsAreRejectedBeforeFollowing() throws {
        let pin = "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        let delegate = try SPKIPinningDelegate(expectedPin: pin)
        let sourceURL = try XCTUnwrap(URL(string: "https://u60.local:19443/v1/device"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://u60.local:9090/api/device"]
        ))
        let task = URLSession.shared.dataTask(with: sourceURL)

        for destination in [
            "http://u60.local:9090/api/device",
            "https://example.com:9443/v1/device",
        ] {
            let capture = RedirectCapture()
            let request = try URLRequest(url: XCTUnwrap(URL(string: destination)))
            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request
            ) { followedRequest in
                capture.record(followedRequest)
            }
            XCTAssertTrue(capture.wasCalled)
            XCTAssertNil(capture.request)
        }
        task.cancel()
    }

    func testMissingServerTrustIsRejectedWithAnExplicitDiagnostic() throws {
        let pin = "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        let delegate = try SPKIPinningDelegate(expectedPin: pin)
        let protectionSpace = URLProtectionSpace(
            host: "u60.local",
            port: 9443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let completed = expectation(description: "authentication challenge completed")
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(delegate.consumeTrustFailure(), .missingServerTrust)
    }

    private func payloadJSON(
        baseURL: String,
        pin: String,
        nonce: String,
        expiresAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"version":1,"base_url":"\(baseURL)","spki_sha256":"\(pin)","pairing_nonce":"\(nonce)","expires_at":"\(formatter.string(from: expiresAt))"}
        """
    }
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (called: Bool, request: URLRequest?) = (false, nil)

    var wasCalled: Bool {
        lock.withLock { state.called }
    }

    var request: URLRequest? {
        lock.withLock { state.request }
    }

    func record(_ request: URLRequest?) {
        lock.withLock { state = (true, request) }
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
    func performDefaultHandling(for _: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {}
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
