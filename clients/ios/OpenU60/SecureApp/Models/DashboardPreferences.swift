import Foundation

struct DashboardPreferences: Codable, Equatable, Sendable {
    var sectionOrder: [String] = []
    var collapsedSections: Set<String> = []
    var refreshSeconds = 0
    var historyRangeSeconds = 86_400
    var hiddenChartSeries: Set<String> = []

    init(
        sectionOrder: [String] = [],
        collapsedSections: Set<String> = [],
        refreshSeconds: Int = 0,
        historyRangeSeconds: Int = 86_400,
        hiddenChartSeries: Set<String> = []
    ) {
        self.sectionOrder = sectionOrder
        self.collapsedSections = collapsedSections
        self.refreshSeconds = refreshSeconds
        self.historyRangeSeconds = historyRangeSeconds
        self.hiddenChartSeries = hiddenChartSeries
    }

    private enum CodingKeys: String, CodingKey {
        case sectionOrder
        case collapsedSections
        case refreshSeconds
        case historyRangeSeconds
        case hiddenChartSeries
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sectionOrder = try values.decodeIfPresent([String].self, forKey: .sectionOrder) ?? []
        collapsedSections = try values.decodeIfPresent(Set<String>.self, forKey: .collapsedSections) ?? []
        refreshSeconds = try values.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 0
        historyRangeSeconds = try values.decodeIfPresent(Int.self, forKey: .historyRangeSeconds) ?? 86_400
        hiddenChartSeries = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenChartSeries) ?? []
    }
}

enum DashboardChartSeriesID {
    static let signalWiFi = "signal.wifi"
    static let signalLTE = "signal.lte"
    static let signal5G = "signal.nr5g"
    static let systemCPU = "system.cpu"
    static let systemMemory = "system.memory"
    static let systemStorage = "system.storage"
    static let thermalPrefix = "thermal."

    static func thermal(sensor: String) -> String {
        "\(thermalPrefix)\(sensor)"
    }
}

struct DashboardPreferencesStore {
    private let store: any SecretStore
    private let account: String

    init(
        store: any SecretStore = KeychainStore(service: "com.lemoncandy42.u60.local-state"),
        account: String = "dashboard-preferences-v1"
    ) {
        self.store = store
        self.account = account
    }

    func load() -> DashboardPreferences {
        guard let data = try? store.read(account: account),
              let value = try? JSONDecoder().decode(DashboardPreferences.self, from: data)
        else { return DashboardPreferences() }
        return value
    }

    func save(_ value: DashboardPreferences) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? store.write(data, account: account)
    }
}
