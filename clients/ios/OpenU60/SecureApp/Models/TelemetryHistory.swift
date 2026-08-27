import Foundation

struct TelemetrySample: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let batteryPercent: Int?
    let lteRSRPdBm: Double?
    let nr5gRSRPdBm: Double?
    let thermalTemperaturesC: [String: Double]

    var id: Date { timestamp }

    init(
        timestamp: Date,
        batteryPercent: Int?,
        lteRSRPdBm: Double?,
        nr5gRSRPdBm: Double?,
        thermalTemperaturesC: [String: Double] = [:]
    ) {
        self.timestamp = timestamp
        self.batteryPercent = batteryPercent
        self.lteRSRPdBm = lteRSRPdBm
        self.nr5gRSRPdBm = nr5gRSRPdBm
        self.thermalTemperaturesC = thermalTemperaturesC
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case batteryPercent
        case lteRSRPdBm
        case nr5gRSRPdBm
        case thermalTemperaturesC
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        batteryPercent = try values.decodeIfPresent(Int.self, forKey: .batteryPercent)
        lteRSRPdBm = try values.decodeIfPresent(Double.self, forKey: .lteRSRPdBm)
        nr5gRSRPdBm = try values.decodeIfPresent(Double.self, forKey: .nr5gRSRPdBm)
        thermalTemperaturesC = try values.decodeIfPresent(
            [String: Double].self,
            forKey: .thermalTemperaturesC
        ) ?? [:]
    }
}

struct TelemetryHistoryStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let minimumSpacing: TimeInterval = 10
    static let maximumSamples = 4_096
    static let maximumThermalSeries = 16

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
        let sanitizedSample = sanitized(sample)
        if let last = result.last,
           sanitizedSample.timestamp >= last.timestamp,
           sanitizedSample.timestamp.timeIntervalSince(last.timestamp) < Self.minimumSpacing
        {
            result[result.count - 1] = replacingTimestamp(of: sanitizedSample, with: last.timestamp)
        } else {
            result.append(sanitizedSample)
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
                .map(sanitized)
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(Self.maximumSamples)
        )
    }

    private func sanitized(_ sample: TelemetrySample) -> TelemetrySample {
        let temperatures = sample.thermalTemperaturesC
            .filter { sensor, value in
                !sensor.isEmpty && sensor.utf8.count <= 64 && value.isFinite && (-40 ... 150).contains(value)
            }
            .sorted { $0.key < $1.key }
            .prefix(Self.maximumThermalSeries)
        return TelemetrySample(
            timestamp: sample.timestamp,
            batteryPercent: sample.batteryPercent,
            lteRSRPdBm: sample.lteRSRPdBm,
            nr5gRSRPdBm: sample.nr5gRSRPdBm,
            thermalTemperaturesC: Dictionary(uniqueKeysWithValues: temperatures.map { ($0.key, $0.value) })
        )
    }

    private func replacingTimestamp(of sample: TelemetrySample, with timestamp: Date) -> TelemetrySample {
        TelemetrySample(
            timestamp: timestamp,
            batteryPercent: sample.batteryPercent,
            lteRSRPdBm: sample.lteRSRPdBm,
            nr5gRSRPdBm: sample.nr5gRSRPdBm,
            thermalTemperaturesC: sample.thermalTemperaturesC
        )
    }
}
