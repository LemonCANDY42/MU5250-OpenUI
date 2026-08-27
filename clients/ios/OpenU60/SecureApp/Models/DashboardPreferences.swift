import Foundation

struct DashboardPreferences: Codable, Equatable, Sendable {
    var sectionOrder: [String] = []
    var collapsedSections: Set<String> = []
    var refreshSeconds = 0
    var historyRangeSeconds = 86_400
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
