import CryptoKit
import Foundation
import Security

final class SPKIPinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum TrustFailure: Equatable {
        case unexpectedAuthenticationMethod
        case missingServerTrust
        case missingPeerCertificate
        case missingPeerPublicKey
        case pinMismatch
        case systemTrustRejected

        var userMessage: String {
            switch self {
            case .unexpectedAuthenticationMethod:
                "The U60 requested an unsupported authentication method. The request was not sent."
            case .missingServerTrust:
                "The U60 did not provide a server certificate. The request was not sent."
            case .missingPeerCertificate:
                "The U60 server certificate chain is incomplete. The request was not sent."
            case .missingPeerPublicKey:
                "The U60 server certificate has no usable public key. The request was not sent."
            case .pinMismatch:
                "The U60 server public key does not match the pairing code. The request was not sent."
            case .systemTrustRejected:
                "The U60 certificate did not pass iOS system trust evaluation. The request was not sent."
            }
        }
    }

    private static let p256SPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    private let expectedPin: String
    private let failureLock = NSLock()
    private var lastTrustFailure: TrustFailure?

    init(expectedPin: String) throws {
        guard DeviceProfile.isValidPin(expectedPin) else { throw LocalSecurityError.invalidPin }
        self.expectedPin = expectedPin
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            record(.unexpectedAuthenticationMethod)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            record(.missingServerTrust)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            record(.missingPeerCertificate)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let key = SecCertificateCopyKey(certificate) else {
            record(.missingPeerPublicKey)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard Self.pin(for: key) == expectedPin else {
            record(.pinMismatch)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // The scanned public-key pin and normal iOS certificate validation are
        // separate requirements. Default handling preserves system validation
        // while returning its real error instead of a misleading cancellation.
        if !SecTrustEvaluateWithError(trust, nil) {
            record(.systemTrustRejected)
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func resetTrustFailure() {
        failureLock.lock()
        lastTrustFailure = nil
        failureLock.unlock()
    }

    func consumeTrustFailure() -> TrustFailure? {
        failureLock.lock()
        defer { failureLock.unlock() }
        defer { lastTrustFailure = nil }
        return lastTrustFailure
    }

    private func record(_ failure: TrustFailure) {
        failureLock.lock()
        lastTrustFailure = failure
        failureLock.unlock()
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The versioned local API has no legitimate redirect. Refusing every
        // 30x prevents a pinned HTTPS request and bearer token from being
        // replayed to plaintext, another host or another port.
        completionHandler(nil)
    }

    static func pin(for key: SecKey) -> String? {
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        guard attributes?[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes?[kSecAttrKeySizeInBits] as? Int == 256,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              raw.count == 65,
              raw.first == 0x04
        else { return nil }
        let digest = SHA256.hash(data: p256SPKIPrefix + raw)
        return "sha256/" + Data(digest).base64EncodedString()
    }
}
