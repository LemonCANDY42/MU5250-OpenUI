import Foundation

/// A presentation guide for router-observed RSSI, not a throughput guarantee.
enum WifiSignalLevel: Equatable, Sendable {
    case veryStrong
    case strong
    case moderate
    case weak
    case veryWeak

    init?(signalDbm: Int) {
        // Zero and out-of-range values are not usable client observations.
        guard (-127..<0).contains(signalDbm) else { return nil }
        switch signalDbm {
        case -49..<0: self = .veryStrong
        case -60 ... -50: self = .strong
        case -70 ..< -60: self = .moderate
        case -80 ..< -70: self = .weak
        default: self = .veryWeak
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .veryStrong: "Very strong"
        case .strong: "Strong"
        case .moderate: "Moderate"
        case .weak: "Weak"
        case .veryWeak: "Very weak"
        }
    }

    var rangeDescription: String {
        switch self {
        case .veryStrong: "RSSI > −50 dBm"
        case .strong: "−60 ≤ RSSI ≤ −50 dBm"
        case .moderate: "−70 ≤ RSSI < −60 dBm"
        case .weak: "−80 ≤ RSSI < −70 dBm"
        case .veryWeak: "RSSI < −80 dBm"
        }
    }
}
