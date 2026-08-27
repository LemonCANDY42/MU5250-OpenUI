import Foundation

struct TelemetrySample: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let batteryPercent: Int?
    let lteRSRPdBm: Double?
    let nr5gRSRPdBm: Double?

    var id: Date { timestamp }
}

struct TelemetryHistoryStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let minimumSpacing: TimeInterval = 10
    static let maximumSamples = 4_096

    private let store: any SecretStore
    private let account: String

    init(
        store: any SecretStore = KeychainStore(service: "com.lemoncandy42.u60.local-state"),
        account: String = "telemetry-history-v1"
    ) {
        self.store = store
        self.account = account
    }

    func load(now: Date = .now) -> [TelemetrySample] {
        guard let data = try? store.read(account: account),
              let decoded = try? JSONDecoder().decode([TelemetrySample].self, from: data)
        else { return [] }
        return pruned(decoded, now: now)
    }

    func append(_ sample: TelemetrySample, to history: [TelemetrySample]) -> [TelemetrySample] {
        var result = pruned(history, now: sample.timestamp)
        if let last = result.last,
           sample.timestamp.timeIntervalSince(last.timestamp) < Self.minimumSpacing
        {
            result[result.count - 1] = sample
        } else {
            result.append(sample)
        }
        result = Array(result.suffix(Self.maximumSamples))
        if let data = try? JSONEncoder().encode(result) {
            try? store.write(data, account: account)
        }
        return result
    }

    private func pruned(_ history: [TelemetrySample], now: Date) -> [TelemetrySample] {
        let cutoff = now.addingTimeInterval(-Self.retention)
        return Array(
            history
                .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(Self.maximumSamples)
        )
    }
}
