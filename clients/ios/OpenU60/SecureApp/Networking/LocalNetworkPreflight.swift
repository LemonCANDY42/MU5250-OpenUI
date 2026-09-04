import Foundation
@preconcurrency import Network

enum LocalNetworkPreflight {
    struct Endpoint: Equatable {
        let host: String
        let port: UInt16
    }

    private static let queue = DispatchQueue(
        label: "com.lemoncandy42.openu60.dev.local-network-preflight"
    )

    static func requestAccess(for profile: DeviceProfile) async throws {
        let endpoint = try endpoint(for: profile)
        let granted = await withCheckedContinuation { continuation in
            let operation = Operation(endpoint: endpoint, continuation: continuation)
            operation.start(on: queue)
        }
        guard granted else { throw LocalSecurityError.localNetworkAccessDenied }
    }

    static func endpoint(for profile: DeviceProfile) throws -> Endpoint {
        guard let host = profile.baseURL.host,
              let port = profile.baseURL.port,
              let port16 = UInt16(exactly: port)
        else {
            throw LocalSecurityError.unsupportedEndpoint
        }
        return Endpoint(host: host, port: port16)
    }

    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: NWConnection
        private var continuation: CheckedContinuation<Bool, Never>?

        init(endpoint: Endpoint, continuation: CheckedContinuation<Bool, Never>) {
            connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: NWEndpoint.Port(rawValue: endpoint.port)!,
                using: .tcp
            )
            self.continuation = continuation
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    finish(granted: true)
                case .waiting, .failed, .cancelled:
                    finish(granted: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        private func finish(granted: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: granted)
        }
    }
}
