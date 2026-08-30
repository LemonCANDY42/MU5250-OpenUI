import Foundation

enum WifiTransmitPowerPreset: Equatable, Sendable {
    case shortRange
    case mediumRange
    case longRange

    init?(percent: Int) {
        switch percent {
        case 40: self = .shortRange
        case 80: self = .mediumRange
        case 100: self = .longRange
        default: return nil
        }
    }
}

func wifiTransmitPowerLabel(_ percent: Int) -> String {
    switch WifiTransmitPowerPreset(percent: percent) {
    case .shortRange: String(localized: "40% · Short range (device preset)")
    case .mediumRange: String(localized: "80% · Medium range (device preset)")
    case .longRange: String(localized: "100% · Long range (device preset)")
    case nil: "\(percent)%"
    }
}
