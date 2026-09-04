import Foundation

enum CellularTechnology: Sendable {
    case lte
    case nr5g
}

/// A presentation guide based on Android's default RSRP thresholds.
/// Carrier-specific modem policies may use different thresholds for their own bars.
enum CellularSignalLevel: Equatable, Sendable {
    case veryStrong
    case strong
    case moderate
    case weak
    case veryWeak

    init?(technology: CellularTechnology, rsrpDbm: Int?) {
        guard let rsrpDbm else { return nil }

        switch technology {
        case .lte:
            guard (-140 ... -44).contains(rsrpDbm) else { return nil }
            switch rsrpDbm {
            case -85 ... -44: self = .veryStrong
            case -95 ... -86: self = .strong
            case -105 ... -96: self = .moderate
            case -115 ... -106: self = .weak
            default: self = .veryWeak
            }
        case .nr5g:
            guard (-156 ... -31).contains(rsrpDbm) else { return nil }
            switch rsrpDbm {
            case -65 ... -31: self = .veryStrong
            case -80 ... -66: self = .strong
            case -90 ... -81: self = .moderate
            case -110 ... -91: self = .weak
            default: self = .veryWeak
            }
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

    func rangeDescription(for technology: CellularTechnology) -> String {
        switch (technology, self) {
        case (.lte, .veryStrong): "RSRP ≥ −85 dBm"
        case (.lte, .strong): "−95 ≤ RSRP < −85 dBm"
        case (.lte, .moderate): "−105 ≤ RSRP < −95 dBm"
        case (.lte, .weak): "−115 ≤ RSRP < −105 dBm"
        case (.lte, .veryWeak): "RSRP < −115 dBm"
        case (.nr5g, .veryStrong): "RSRP ≥ −65 dBm"
        case (.nr5g, .strong): "−80 ≤ RSRP < −65 dBm"
        case (.nr5g, .moderate): "−90 ≤ RSRP < −80 dBm"
        case (.nr5g, .weak): "−110 ≤ RSRP < −90 dBm"
        case (.nr5g, .veryWeak): "RSRP < −110 dBm"
        }
    }
}
