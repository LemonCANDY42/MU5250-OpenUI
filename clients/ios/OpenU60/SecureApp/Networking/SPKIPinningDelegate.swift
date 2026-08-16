import CryptoKit
import Foundation
import Security

final class SPKIPinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let p256SPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    private let expectedPin: String

    init(expectedPin: String) throws {
        guard DeviceProfile.isValidPin(expectedPin) else { throw LocalSecurityError.invalidPin }
        self.expectedPin = expectedPin
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first,
              let key = SecCertificateCopyKey(certificate),
              Self.pin(for: key) == expectedPin
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
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
