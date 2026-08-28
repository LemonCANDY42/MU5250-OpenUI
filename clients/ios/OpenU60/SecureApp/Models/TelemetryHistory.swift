import Foundation

struct TelemetrySample: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let continuityID: Int
    let batteryPercent: Int?
    let lteRSRPdBm: Double?
    let nr5gRSRPdBm: Double?
    let wifiSignalDbm: Double?
    let thermalTemperaturesC: [String: Double]
    let cpuUsagePercent: Double?
    let memoryUsedPercent: Double?
    let storageUsedPercent: Double?

    var id: Date { timestamp }

    init(
        timestamp: Date,
        continuityID: Int = 0,
        batteryPercent: Int?,
        lteRSRPdBm: Double?,
        nr5gRSRPdBm: Double?,
        wifiSignalDbm: Double? = nil,
        thermalTemperaturesC: [String: Double] = [:],
        cpuUsagePercent: Double? = nil,
        memoryUsedPercent: Double? = nil,
        storageUsedPercent: Double? = nil
    ) {
        self.timestamp = timestamp
        self.continuityID = continuityID
        self.batteryPercent = batteryPercent
        self.lteRSRPdBm = lteRSRPdBm
        self.nr5gRSRPdBm = nr5gRSRPdBm
        self.wifiSignalDbm = wifiSignalDbm
        self.thermalTemperaturesC = thermalTemperaturesC
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsedPercent = memoryUsedPercent
        self.storageUsedPercent = storageUsedPercent
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case continuityID
        case batteryPercent
        case lteRSRPdBm
        case nr5gRSRPdBm
        case wifiSignalDbm
        case thermalTemperaturesC
        case cpuUsagePercent
        case memoryUsedPercent
        case storageUsedPercent
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        continuityID = try values.decodeIfPresent(Int.self, forKey: .continuityID) ?? 0
        batteryPercent = try values.decodeIfPresent(Int.self, forKey: .batteryPercent)
        lteRSRPdBm = try values.decodeIfPresent(Double.self, forKey: .lteRSRPdBm)
        nr5gRSRPdBm = try values.decodeIfPresent(Double.self, forKey: .nr5gRSRPdBm)
        wifiSignalDbm = try values.decodeIfPresent(Double.self, forKey: .wifiSignalDbm)
        thermalTemperaturesC = try values.decodeIfPresent(
            [String: Double].self,
            forKey: .thermalTemperaturesC
        ) ?? [:]
        cpuUsagePercent = try values.decodeIfPresent(Double.self, forKey: .cpuUsagePercent)
        memoryUsedPercent = try values.decodeIfPresent(Double.self, forKey: .memoryUsedPercent)
        storageUsedPercent = try values.decodeIfPresent(Double.self, forKey: .storageUsedPercent)
    }
}

struct TelemetryHistoryStore {
    static let retention: TimeInterval = 24 * 60 * 60
    static let minimumSpacing: TimeInterval = 5
    static let maximumSamples = 2_000
    static let maximumThermalSeries = 16

    private struct Bucket: Equatable {
        let spacing: TimeInterval
        let index: Int64
        let continuityID: Int
    }

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
        let normalized = pruned(decoded, now: now)
        if normalized != decoded, let migrated = try? JSONEncoder().encode(normalized) {
            try? store.write(migrated, account: account)
        }
        return normalized
    }

    func append(_ sample: TelemetrySample, to history: [TelemetrySample]) -> [TelemetrySample] {
        let result = pruned(history + [sample], now: sample.timestamp)
        if let data = try? JSONEncoder().encode(result) {
            try? store.write(data, account: account)
        }
        return result
    }

    private func pruned(_ history: [TelemetrySample], now: Date) -> [TelemetrySample] {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let samples = history
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
            .map(sanitized)
            .sorted { $0.timestamp < $1.timestamp }
        var coalesced: [TelemetrySample] = []
        coalesced.reserveCapacity(min(samples.count, Self.maximumSamples))
        var lastBucket: Bucket?
        for sample in samples {
            let spacing = Self.retainedSpacing(for: sample.timestamp, now: now)
            let bucket = Bucket(
                spacing: spacing,
                index: Int64(floor(sample.timestamp.timeIntervalSince1970 / spacing)),
                continuityID: sample.continuityID
            )
            if bucket == lastBucket {
                coalesced[coalesced.count - 1] = sample
            } else {
                coalesced.append(sample)
                lastBucket = bucket
            }
        }
        return Array(coalesced.suffix(Self.maximumSamples))
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
            continuityID: max(0, sample.continuityID),
            batteryPercent: sample.batteryPercent,
            lteRSRPdBm: sanitizedCellularSignal(sample.lteRSRPdBm),
            nr5gRSRPdBm: sanitizedCellularSignal(sample.nr5gRSRPdBm),
            wifiSignalDbm: sanitizedWifiSignal(sample.wifiSignalDbm),
            thermalTemperaturesC: Dictionary(uniqueKeysWithValues: temperatures.map { ($0.key, $0.value) }),
            cpuUsagePercent: sanitizedPercent(sample.cpuUsagePercent),
            memoryUsedPercent: sanitizedPercent(sample.memoryUsedPercent),
            storageUsedPercent: sanitizedPercent(sample.storageUsedPercent)
        )
    }

    static func retainedSpacing(for timestamp: Date, now: Date) -> TimeInterval {
        let age = max(0, now.timeIntervalSince(timestamp))
        return switch age {
        case 0 ... 3_600:
            5
        case 3_600 ... 21_600:
            30
        default:
            120
        }
    }

    private func sanitizedPercent(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0 ... 100).contains($0) ? $0 : nil }
    }

    private func sanitizedWifiSignal(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (-127 ... 0).contains($0) ? $0 : nil }
    }

    private func sanitizedCellularSignal(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (-160 ... -20).contains($0) ? $0 : nil }
    }
}

struct TelemetryChartPoint: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let timestamp: Date
        let continuityID: Int
    }

    let timestamp: Date
    let value: Double
    let continuityID: Int

    var id: ID { ID(timestamp: timestamp, continuityID: continuityID) }
}

struct TelemetryChartSegment: Identifiable, Equatable, Sendable {
    let id: TelemetryChartPoint.ID
    let points: [TelemetryChartPoint]
}

enum TelemetryChartProjection {
    static func spacing(forRangeSeconds rangeSeconds: Int) -> TimeInterval {
        switch rangeSeconds {
        case ...3_600:
            5
        case ...21_600:
            30
        default:
            120
        }
    }

    static func segments(
        from samples: [TelemetrySample],
        rangeSeconds: Int,
        expectedRefreshSeconds: Int,
        now: Date = .now,
        value: (TelemetrySample) -> Double?
    ) -> [TelemetryChartSegment] {
        let spacing = spacing(forRangeSeconds: rangeSeconds)
        let cutoff = now.addingTimeInterval(-TimeInterval(rangeSeconds))
        let source = samples
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
            .sorted { $0.timestamp < $1.timestamp }

        var projected: [TelemetryChartPoint] = []
        var lastBucket: Int64?
        var lastContinuityID: Int?
        for sample in source {
            guard let metric = value(sample), metric.isFinite else { continue }
            let bucket = Int64(floor(sample.timestamp.timeIntervalSince1970 / spacing))
            let point = TelemetryChartPoint(
                timestamp: sample.timestamp,
                value: metric,
                continuityID: sample.continuityID
            )
            if bucket == lastBucket, sample.continuityID == lastContinuityID {
                projected[projected.count - 1] = point
            } else {
                projected.append(point)
                lastBucket = bucket
                lastContinuityID = sample.continuityID
            }
        }

        let expectedSpacing = expectedRefreshSeconds > 0
            ? TimeInterval(expectedRefreshSeconds)
            : spacing
        let maximumContinuousGap = max(spacing, expectedSpacing) * 2.5
        var result: [TelemetryChartSegment] = []
        var current: [TelemetryChartPoint] = []
        for point in projected {
            if let previous = current.last,
               (point.continuityID != previous.continuityID
                   || point.timestamp.timeIntervalSince(previous.timestamp) > maximumContinuousGap)
            {
                result.append(TelemetryChartSegment(id: current[0].id, points: current))
                current = []
            }
            current.append(point)
        }
        if let first = current.first {
            result.append(TelemetryChartSegment(id: first.id, points: current))
        }
        return result
    }
}
