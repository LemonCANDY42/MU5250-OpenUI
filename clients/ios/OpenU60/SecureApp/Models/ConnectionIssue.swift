import Foundation
import OpenAPIRuntime

enum ConnectionIssue: Equatable {
    case weak
    case disconnected

    var message: String {
        switch self {
        case .weak:
            String(localized: "Connection is weak. Showing the latest available status.")
        case .disconnected:
            String(localized: "U60 disconnected. Updates will resume after you return to its Wi-Fi.")
        }
    }

    var systemImage: String {
        switch self {
        case .weak: "wifi.exclamationmark"
        case .disconnected: "wifi.slash"
        }
    }

    static func classify(_ error: any Error) -> Self? {
        if case .transportSecurity = error as? AgentServiceError {
            return nil
        }

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
                let urlCode = URLError.Code(rawValue: nsError.code)
                switch urlCode {
                case .notConnectedToInternet,
                     .cannotFindHost,
                     .cannotConnectToHost,
                     .dnsLookupFailed,
                     .internationalRoamingOff,
                     .callIsActive,
                     .dataNotAllowed,
                     .cannotLoadFromNetwork:
                    return .disconnected
                case .timedOut,
                     .networkConnectionLost,
                     .resourceUnavailable,
                     .backgroundSessionWasDisconnected:
                    bestMatch = .weak
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
