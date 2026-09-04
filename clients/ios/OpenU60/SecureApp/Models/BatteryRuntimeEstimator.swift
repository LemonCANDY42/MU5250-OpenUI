import Foundation

enum BatteryRuntimeEstimateConfidence: Equatable, Sendable {
    case preliminary
    case established
}

struct BatteryRuntimeEstimate: Equatable, Sendable {
    let typicalSeconds: Int
    let conservativeSeconds: Int
    let reservePercent: Int
    let observationSeconds: Int
    let confidence: BatteryRuntimeEstimateConfidence
}

enum BatteryRuntimeEstimator {
    static let reservePercent = 5
    static let observationWindow: TimeInterval = 30 * 60
    static let preliminaryObservation: TimeInterval = 60
    static let establishedObservation: TimeInterval = 5 * 60
    static let preliminaryBucketSpacing: TimeInterval = 10
    static let establishedBucketSpacing: TimeInterval = 30
    static let maximumSampleGap: TimeInterval = 3 * 60
    static let maximumEstimateSeconds = 30 * 24 * 60 * 60

    private struct RateBucket {
        let timestamp: Date
        let currentMA: Double
    }

    static func estimate(
        from history: [TelemetrySample],
        now: Date = .now
    ) -> BatteryRuntimeEstimate? {
        let cutoff = now.addingTimeInterval(-observationWindow)
        let source = history
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(60) }
            .sorted { $0.timestamp < $1.timestamp }

        guard
            let latest = source.last,
            now.timeIntervalSince(latest.timestamp) <= maximumSampleGap,
            latest.batteryState?.lowercased() == "discharging",
            let capacityPercent = latest.batteryPercent,
            capacityPercent > reservePercent,
            let fullCapacityMAh = latest.batteryLearnedFullCapacityMah
                ?? latest.batteryDesignCapacityMah,
            fullCapacityMAh > 0
        else {
            return nil
        }

        let continuous = continuousDischargeSuffix(
            of: source,
            continuityID: latest.continuityID
        )
        guard
            let first = continuous.first,
            let last = continuous.last
        else {
            return nil
        }
        let observationSeconds = last.timestamp.timeIntervalSince(first.timestamp)
        guard observationSeconds >= preliminaryObservation else { return nil }

        let confidence: BatteryRuntimeEstimateConfidence = observationSeconds >= establishedObservation
            ? .established
            : .preliminary
        let bucketSpacing = confidence == .established
            ? establishedBucketSpacing
            : preliminaryBucketSpacing
        let minimumBucketCount = confidence == .established ? 6 : 3

        let buckets = rateBuckets(from: continuous, spacing: bucketSpacing)
        guard buckets.count >= minimumBucketCount else { return nil }

        let typicalCurrentMA = timeWeightedRate(
            buckets,
            timeConstant: confidence == .established ? 10 * 60 : 2 * 60
        )
        let conservativeCurrentMA = max(
            typicalCurrentMA,
            percentile(buckets.map(\.currentMA), probability: 0.9)
        )
        guard typicalCurrentMA > 0, conservativeCurrentMA > 0 else { return nil }

        let usableCapacityMAh = Double(fullCapacityMAh)
            * Double(capacityPercent - reservePercent)
            / 100
        guard usableCapacityMAh > 0 else { return nil }

        return BatteryRuntimeEstimate(
            typicalSeconds: boundedSeconds(
                usableCapacityMAh / typicalCurrentMA * 3_600
            ),
            conservativeSeconds: boundedSeconds(
                usableCapacityMAh / conservativeCurrentMA * 3_600
            ),
            reservePercent: reservePercent,
            observationSeconds: Int(observationSeconds.rounded(.down)),
            confidence: confidence
        )
    }

    private static func continuousDischargeSuffix(
        of samples: [TelemetrySample],
        continuityID: Int
    ) -> [TelemetrySample] {
        var suffix: [TelemetrySample] = []
        var newerTimestamp: Date?

        for sample in samples.reversed() {
            guard
                sample.continuityID == continuityID,
                sample.batteryState?.lowercased() == "discharging",
                let currentMA = sample.batteryCurrentMa,
                currentMA != 0,
                currentMA != .min,
                abs(currentMA) <= 1_000_000
            else {
                break
            }
            if let newerTimestamp,
               newerTimestamp.timeIntervalSince(sample.timestamp) > maximumSampleGap
            {
                break
            }
            suffix.append(sample)
            newerTimestamp = sample.timestamp
        }
        return suffix.reversed()
    }

    private static func rateBuckets(
        from samples: [TelemetrySample],
        spacing: TimeInterval
    ) -> [RateBucket] {
        let grouped = Dictionary(grouping: samples) { sample in
            Int64(floor(sample.timestamp.timeIntervalSince1970 / spacing))
        }
        return grouped.keys.sorted().compactMap { key in
            let values = grouped[key, default: []].compactMap { sample -> Double? in
                guard let currentMA = sample.batteryCurrentMa else { return nil }
                return Double(abs(currentMA))
            }
            guard !values.isEmpty else { return nil }
            return RateBucket(
                timestamp: Date(timeIntervalSince1970: Double(key) * spacing),
                currentMA: percentile(values, probability: 0.5)
            )
        }
    }

    private static func timeWeightedRate(
        _ buckets: [RateBucket],
        timeConstant: TimeInterval
    ) -> Double {
        guard let latestTimestamp = buckets.last?.timestamp else { return 0 }
        var weightedTotal = 0.0
        var totalWeight = 0.0
        for bucket in buckets {
            let age = max(0, latestTimestamp.timeIntervalSince(bucket.timestamp))
            let weight = exp(-age / timeConstant)
            weightedTotal += bucket.currentMA * weight
            totalWeight += weight
        }
        return totalWeight > 0 ? weightedTotal / totalWeight : 0
    }

    private static func percentile(_ values: [Double], probability: Double) -> Double {
        let sorted = values.sorted()
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = min(max(probability, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func boundedSeconds(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return min(maximumEstimateSeconds, Int(value.rounded()))
    }
}
