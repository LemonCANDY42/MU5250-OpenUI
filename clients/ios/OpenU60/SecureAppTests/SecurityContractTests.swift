import CryptoKit
import Foundation
import OpenAPIRuntime
@testable import OpenU60
import Security
import XCTest

final class SecurityContractTests: XCTestCase {
    func testConnectionIssueClassifiesExpectedReadPathFailures() {
        let offline = ClientError(
            operationID: "getCapabilities",
            operationInput: "test",
            causeDescription: "transport failed",
            underlyingError: URLError(.notConnectedToInternet)
        )
        XCTAssertEqual(ConnectionIssue.classify(offline), .disconnected)
        XCTAssertEqual(ConnectionIssue.classify(URLError(.timedOut)), .weak)

        let nested = NSError(
            domain: "OpenU60Tests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotConnectToHost)]
        )
        XCTAssertEqual(ConnectionIssue.classify(nested), .disconnected)
    }

    func testConnectionIssueDoesNotHideCancellationOrTransportSecurityFailures() {
        XCTAssertNil(ConnectionIssue.classify(URLError(.cancelled)))
        XCTAssertNil(ConnectionIssue.classify(URLError(.secureConnectionFailed)))
        XCTAssertNil(ConnectionIssue.classify(AgentServiceError.transportSecurity("certificate rejected")))
        XCTAssertNil(ConnectionIssue.classify(AgentServiceError.invalidResponse))
    }

    @MainActor
    func testReadSessionRecoveryRenewsOnceAfterSessionExpiry() async throws {
        var attempts = 0
        var renewals = 0

        let value = try await ReadSessionRecovery.run {
            attempts += 1
            if attempts == 1 {
                throw AgentServiceError.authenticationRequired
            }
            return 42
        } renew: {
            renewals += 1
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(renewals, 1)
    }

    @MainActor
    func testReadSessionRecoveryDoesNotLoopAfterSecondSessionRejection() async {
        var attempts = 0
        var renewals = 0

        do {
            let _: Int = try await ReadSessionRecovery.run {
                attempts += 1
                throw AgentServiceError.authenticationRequired
            } renew: {
                renewals += 1
            }
            XCTFail("expected the second authentication rejection to propagate")
        } catch AgentServiceError.authenticationRequired {
            // Expected: one renewal and one bounded retry only.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(renewals, 1)
    }

    func testGeneratedAggregateSnapshotPreservesPartialSuccess() throws {
        let snapshot = try JSONDecoder().decode(
            Components.Schemas.DashboardSnapshot.self,
            from: Data(
                #"{"report":{"adapter":"b04","firmware_target":"hk_b04","capabilities":[{"id":"wifi_status","status":"available","recovery":{"required":false}},{"id":"battery_status","status":"degraded","recovery":{"required":false}}]},"wifi":{"enabled":true,"bands":[],"features":{"wifi7_active":false,"version_switch_reported_supported":false,"version_switch_state_available":false,"mlo_supported":false,"mlo_enabled":false,"band_steering_supported":false,"band_steering_enabled":false}},"charging":{"capacity_percent":95,"paused":false},"failures":[{"component":"battery_status","error":{"code":"source_unavailable","message":"temporarily unavailable","recovery":{"required":false}}}]}"#.utf8
            )
        )

        XCTAssertTrue(try XCTUnwrap(snapshot.wifi).enabled)
        XCTAssertEqual(try XCTUnwrap(snapshot.charging).capacityPercent, 95)
        XCTAssertNil(snapshot.battery)
        XCTAssertEqual(snapshot.failures.count, 1)
        XCTAssertEqual(snapshot.failures[0].component, .batteryStatus)
        XCTAssertEqual(snapshot.failures[0].error.code, "source_unavailable")
    }

    func testGeneratedWifiBandDecodesOptionalActiveChannel() throws {
        let band = try JSONDecoder().decode(
            Components.Schemas.WifiBandStatus.self,
            from: Data(
                #"{"band":"2.4 GHz","enabled":true,"access_point_enabled":false,"ssid":"Two","hidden":false,"encryption":"psk2","channel":"auto","active_channel":6,"bandwidth":"HE40"}"#.utf8
            )
        )

        XCTAssertEqual(band.channel, "auto")
        XCTAssertEqual(band.activeChannel, 6)
        XCTAssertEqual(band.accessPointEnabled, false)
    }

    func testStockTransmitPowerPresetsMatchB04DistanceLabels() {
        XCTAssertEqual(WifiTransmitPowerPreset(percent: 40), .shortRange)
        XCTAssertEqual(WifiTransmitPowerPreset(percent: 80), .mediumRange)
        XCTAssertEqual(WifiTransmitPowerPreset(percent: 100), .longRange)
        XCTAssertNil(WifiTransmitPowerPreset(percent: 20))
        XCTAssertNil(WifiTransmitPowerPreset(percent: 60))
    }

    func testTelemetryHistoryIsBoundedDeviceLocalAndReplacesRapidSamples() throws {
        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TelemetrySample(
            timestamp: start,
            batteryPercent: 80,
            lteRSRPdBm: -90,
            nr5gRSRPdBm: nil,
            wifiSignalDbm: -55,
            thermalTemperaturesC: ["cpu_0": 42]
        )
        let replacement = TelemetrySample(
            timestamp: start.addingTimeInterval(2),
            batteryPercent: 79,
            lteRSRPdBm: -91,
            nr5gRSRPdBm: -88,
            wifiSignalDbm: -54,
            thermalTemperaturesC: ["cpu_0": 43],
            cpuUsagePercent: 12.5,
            memoryUsedPercent: 75,
            storageUsedPercent: 50
        )
        let later = TelemetrySample(
            timestamp: start.addingTimeInterval(5),
            batteryPercent: 78,
            lteRSRPdBm: -92,
            nr5gRSRPdBm: -89,
            wifiSignalDbm: -53,
            thermalTemperaturesC: ["cpu_0": 44]
        )

        var history = store.append(first, to: [])
        history = store.append(replacement, to: history)
        let retainedReplacement = TelemetrySample(
            timestamp: replacement.timestamp,
            batteryPercent: replacement.batteryPercent,
            lteRSRPdBm: replacement.lteRSRPdBm,
            nr5gRSRPdBm: replacement.nr5gRSRPdBm,
            wifiSignalDbm: replacement.wifiSignalDbm,
            thermalTemperaturesC: replacement.thermalTemperaturesC,
            cpuUsagePercent: replacement.cpuUsagePercent,
            memoryUsedPercent: replacement.memoryUsedPercent,
            storageUsedPercent: replacement.storageUsedPercent
        )
        XCTAssertEqual(history, [retainedReplacement])
        history = store.append(later, to: history)
        XCTAssertEqual(history, [retainedReplacement, later])
        XCTAssertEqual(history.last?.wifiSignalDbm, -53)
        XCTAssertEqual(store.load(now: later.timestamp), history)
    }

    func testTelemetryHistoryDecodesLegacySamplesAndBoundsThermalSeries() throws {
        struct LegacySample: Codable {
            let timestamp: Date
            let batteryPercent: Int?
            let lteRSRPdBm: Double?
            let nr5gRSRPdBm: Double?
        }

        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try memory.write(
            JSONEncoder().encode([
                LegacySample(timestamp: now, batteryPercent: 50, lteRSRPdBm: -90, nr5gRSRPdBm: nil),
            ]),
            account: "history"
        )
        XCTAssertEqual(store.load(now: now).first?.thermalTemperaturesC, [:])
        XCTAssertNil(store.load(now: now).first?.cpuUsagePercent)
        XCTAssertNil(store.load(now: now).first?.memoryUsedPercent)
        XCTAssertNil(store.load(now: now).first?.storageUsedPercent)
        XCTAssertNil(store.load(now: now).first?.wifiSignalDbm)

        let temperatures = Dictionary(uniqueKeysWithValues: (0 ..< 32).map { ("sensor_\($0)", Double($0)) })
        let history = store.append(
            TelemetrySample(
                timestamp: now.addingTimeInterval(10),
                batteryPercent: nil,
                lteRSRPdBm: 0,
                nr5gRSRPdBm: -200,
                wifiSignalDbm: 1,
                thermalTemperaturesC: temperatures.merging(["invalid": .infinity]) { current, _ in current }
            ),
            to: []
        )
        XCTAssertEqual(history.first?.thermalTemperaturesC.count, TelemetryHistoryStore.maximumThermalSeries)
        XCTAssertNil(history.first?.thermalTemperaturesC["invalid"])
        XCTAssertNil(history.first?.wifiSignalDbm)
        XCTAssertNil(history.first?.lteRSRPdBm)
        XCTAssertNil(history.first?.nr5gRSRPdBm)
    }

    func testTelemetryHistoryUsesTieredRetentionAndStaysBounded() throws {
        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let now = Date(timeIntervalSince1970: 1_800_086_400)
        var ages = Array(stride(from: 0, through: 3_600, by: 2))
        ages.append(contentsOf: stride(from: 3_602, through: 21_600, by: 15))
        ages.append(contentsOf: stride(from: 21_615, through: 86_400, by: 60))
        let samples = ages.map { age in
            TelemetrySample(
                timestamp: now.addingTimeInterval(-TimeInterval(age)),
                batteryPercent: 50,
                lteRSRPdBm: -90,
                nr5gRSRPdBm: nil,
                cpuUsagePercent: age == 0 ? -1 : 25,
                memoryUsedPercent: 50,
                storageUsedPercent: age == 0 ? 101 : 75
            )
        }
        try memory.write(JSONEncoder().encode(samples), account: "history")
        let loaded = store.load(now: now)

        XCTAssertLessThanOrEqual(loaded.count, TelemetryHistoryStore.maximumSamples)
        XCTAssertGreaterThan(loaded.count, 1_700)
        XCTAssertGreaterThanOrEqual(
            loaded.first?.timestamp ?? .distantPast,
            now.addingTimeInterval(-TelemetryHistoryStore.retention)
        )
        let buckets = loaded.map { sample in
            let spacing = TelemetryHistoryStore.retainedSpacing(for: sample.timestamp, now: now)
            return "\(Int(spacing)):\(Int64(floor(sample.timestamp.timeIntervalSince1970 / spacing))):\(sample.continuityID)"
        }
        XCTAssertEqual(Set(buckets).count, buckets.count)
        XCTAssertNil(loaded.last?.cpuUsagePercent)
        XCTAssertNil(loaded.last?.storageUsedPercent)
        XCTAssertEqual(loaded.last?.memoryUsedPercent, 50)
    }

    func testTelemetryHistoryMigratesDenseLegacySamplesToTieredSpacing() throws {
        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = (0 ... 60).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 10),
                batteryPercent: 50 + index,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }
        try memory.write(JSONEncoder().encode(legacy), account: "history")

        let loaded = store.load(now: start.addingTimeInterval(7 * 3_600))
        XCTAssertEqual(loaded.map(\.timestamp), [
            start.addingTimeInterval(110),
            start.addingTimeInterval(230),
            start.addingTimeInterval(350),
            start.addingTimeInterval(470),
            start.addingTimeInterval(590),
            start.addingTimeInterval(600),
        ])
        XCTAssertEqual(loaded.map(\.batteryPercent), [61, 73, 85, 97, 109, 110])

        let migratedData = try XCTUnwrap(try memory.read(account: "history"))
        XCTAssertEqual(try JSONDecoder().decode([TelemetrySample].self, from: migratedData), loaded)
    }

    func testTelemetryChartProjectionUsesRangeGranularityAndBreaksMissingIntervals() {
        XCTAssertEqual(TelemetryChartProjection.spacing(forRangeSeconds: 3_600), 5)
        XCTAssertEqual(TelemetryChartProjection.spacing(forRangeSeconds: 21_600), 30)
        XCTAssertEqual(TelemetryChartProjection.spacing(forRangeSeconds: 86_400), 120)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            TelemetrySample(timestamp: start, batteryPercent: 50, lteRSRPdBm: nil, nr5gRSRPdBm: nil),
            TelemetrySample(
                timestamp: start.addingTimeInterval(30),
                batteryPercent: 51,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
            TelemetrySample(
                timestamp: start.addingTimeInterval(60),
                batteryPercent: 52,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
            TelemetrySample(
                timestamp: start.addingTimeInterval(6 * 3_600),
                continuityID: 1,
                batteryPercent: 53,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
        ]

        let segments = TelemetryChartProjection.segments(
            from: samples,
            rangeSeconds: 86_400,
            expectedRefreshSeconds: 15,
            now: start.addingTimeInterval(6 * 3_600),
            value: { $0.batteryPercent.map(Double.init) }
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.points.count), [1, 1])
        XCTAssertEqual(segments.map { $0.points[0].value }, [52, 53])
    }

    func testTelemetryChartProjectionDownsamplesTwoSecondRefreshToFiveSecondPoints() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0 ... 30).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 2),
                batteryPercent: 50 + index,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }
        let segments = TelemetryChartProjection.segments(
            from: samples,
            rangeSeconds: 3_600,
            expectedRefreshSeconds: 2,
            now: start.addingTimeInterval(60),
            value: { $0.batteryPercent.map(Double.init) }
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].points.count, 13)
        XCTAssertEqual(segments[0].points.first?.value, 52)
        XCTAssertEqual(segments[0].points.last?.value, 80)
    }

    func testTelemetryChartProjectionBreaksOnKnownConnectionLoss() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            TelemetrySample(
                timestamp: start,
                continuityID: 0,
                batteryPercent: 50,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
            TelemetrySample(
                timestamp: start.addingTimeInterval(5),
                continuityID: 0,
                batteryPercent: 51,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
            TelemetrySample(
                timestamp: start.addingTimeInterval(10),
                continuityID: 1,
                batteryPercent: 52,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            ),
        ]
        let segments = TelemetryChartProjection.segments(
            from: samples,
            rangeSeconds: 3_600,
            expectedRefreshSeconds: 2,
            now: start.addingTimeInterval(10),
            value: { $0.batteryPercent.map(Double.init) }
        )

        XCTAssertEqual(segments.map(\.points.count), [2, 1])
    }

    func testGeneratedStatusTypesDecodeEarlierV1PayloadsWithoutOptionalMetrics() throws {
        let system = try JSONDecoder().decode(
            Components.Schemas.SystemStatus.self,
            from: Data(
                #"{"hostname":"u60","uptime_seconds":42,"load_average":[0,0,0],"kernel":"Linux"}"#.utf8
            )
        )
        XCTAssertNil(system.cpuUsagePercent)
        XCTAssertNil(system.memoryUsedPercent)
        XCTAssertNil(system.storageUsedPercent)

        let battery = try JSONDecoder().decode(
            Components.Schemas.BatteryStatus.self,
            from: Data(
                #"{"state":"Charging","capacity_percent":80,"voltage_mv":4000,"current_ma":100,"power_mw":400,"temperature_c":30}"#.utf8
            )
        )
        XCTAssertNil(battery.health)
        XCTAssertNil(battery.cycleCount)
        XCTAssertNil(battery.learnedFullCapacityMah)
        XCTAssertNil(battery.timeToFullSeconds)
    }

    func testBatteryCapacityHealthUsesDesignCapacityWithoutClamping() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                batteryCapacityHealthPercent(
                    learnedFullCapacityMah: 5_250,
                    designCapacityMah: 5_000
                )
            ),
            105,
            accuracy: 0.000_001
        )
        XCTAssertNil(
            batteryCapacityHealthPercent(
                learnedFullCapacityMah: nil,
                designCapacityMah: 5_000
            )
        )
        XCTAssertNil(
            batteryCapacityHealthPercent(
                learnedFullCapacityMah: 5_000,
                designCapacityMah: 0
            )
        )
    }

    func testBatteryRuntimeEstimateUsesLearnedCapacityAndFivePercentReserve() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let history = dischargeHistory(
            start: start,
            minutes: 10,
            currentMA: -500,
            capacityPercent: 50,
            learnedFullCapacityMAh: 5_000,
            designCapacityMAh: 6_000
        )

        let estimate = try XCTUnwrap(
            BatteryRuntimeEstimator.estimate(from: history, now: start.addingTimeInterval(10 * 60))
        )
        XCTAssertEqual(estimate.typicalSeconds, 16_200)
        XCTAssertEqual(estimate.conservativeSeconds, 16_200)
        XCTAssertEqual(estimate.reservePercent, 5)
        XCTAssertEqual(estimate.observationSeconds, 600)
        XCTAssertEqual(estimate.confidence, .established)
    }

    func testBatteryRuntimeEstimateProvidesPreliminaryResultAfterOneMinute() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let history = (0 ... 6).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 10),
                batteryPercent: 50,
                batteryState: "Discharging",
                batteryCurrentMa: -500,
                batteryLearnedFullCapacityMah: 5_000,
                batteryDesignCapacityMah: 6_000,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }

        let estimate = try XCTUnwrap(
            BatteryRuntimeEstimator.estimate(from: history, now: start.addingTimeInterval(60))
        )
        XCTAssertEqual(estimate.typicalSeconds, 16_200)
        XCTAssertEqual(estimate.conservativeSeconds, 16_200)
        XCTAssertEqual(estimate.observationSeconds, 60)
        XCTAssertEqual(estimate.confidence, .preliminary)
    }

    func testBatteryRuntimeEstimateRequiresThreeEarlyBuckets() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sparse = [0, 60].map { seconds in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(seconds)),
                batteryPercent: 50,
                batteryState: "Discharging",
                batteryCurrentMa: -500,
                batteryLearnedFullCapacityMah: 5_000,
                batteryDesignCapacityMah: nil,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }
        XCTAssertNil(
            BatteryRuntimeEstimator.estimate(from: sparse, now: start.addingTimeInterval(60))
        )
    }

    func testBatteryRuntimeEstimateUsesPeakPercentileForConservativeTime() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let history = (0 ... 20).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 30),
                batteryPercent: 60,
                batteryState: "Discharging",
                batteryCurrentMa: index >= 17 ? -1_000 : -400,
                batteryLearnedFullCapacityMah: 5_000,
                batteryDesignCapacityMah: 5_000,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }

        let estimate = try XCTUnwrap(
            BatteryRuntimeEstimator.estimate(from: history, now: start.addingTimeInterval(10 * 60))
        )
        XCTAssertLessThan(estimate.conservativeSeconds, estimate.typicalSeconds)
        XCTAssertEqual(estimate.conservativeSeconds, 9_900)
    }

    func testBatteryRuntimeEstimateDoesNotInventAcrossGapsOrCharging() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var history = dischargeHistory(
            start: start,
            minutes: 4,
            currentMA: -500,
            capacityPercent: 50,
            learnedFullCapacityMAh: 5_000,
            designCapacityMAh: 5_000
        )
        history.append(contentsOf: dischargeHistory(
            start: start.addingTimeInterval(8 * 60),
            minutes: 4,
            currentMA: -500,
            capacityPercent: 49,
            learnedFullCapacityMAh: 5_000,
            designCapacityMAh: 5_000
        ))
        let afterGap = BatteryRuntimeEstimator.estimate(
            from: history,
            now: start.addingTimeInterval(12 * 60)
        )
        XCTAssertEqual(afterGap?.observationSeconds, 240)
        XCTAssertEqual(afterGap?.confidence, .preliminary)

        let charging = history + [TelemetrySample(
            timestamp: start.addingTimeInterval(12 * 60 + 30),
            batteryPercent: 49,
            batteryState: "Charging",
            batteryCurrentMa: 500,
            batteryLearnedFullCapacityMah: 5_000,
            batteryDesignCapacityMah: 5_000,
            lteRSRPdBm: nil,
            nr5gRSRPdBm: nil
        )]
        XCTAssertNil(
            BatteryRuntimeEstimator.estimate(from: charging, now: start.addingTimeInterval(12 * 60 + 30))
        )
    }

    func testBatteryRuntimeEstimateRequiresUsableCapacityAndFreshSamples() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let atReserve = dischargeHistory(
            start: start,
            minutes: 10,
            currentMA: -500,
            capacityPercent: 5,
            learnedFullCapacityMAh: nil,
            designCapacityMAh: 5_000
        )
        XCTAssertNil(
            BatteryRuntimeEstimator.estimate(from: atReserve, now: start.addingTimeInterval(10 * 60))
        )

        let valid = dischargeHistory(
            start: start,
            minutes: 10,
            currentMA: -500,
            capacityPercent: 50,
            learnedFullCapacityMAh: nil,
            designCapacityMAh: 5_000
        )
        XCTAssertNotNil(
            BatteryRuntimeEstimator.estimate(from: valid, now: start.addingTimeInterval(10 * 60))
        )
        XCTAssertNil(
            BatteryRuntimeEstimator.estimate(from: valid, now: start.addingTimeInterval(14 * 60))
        )
    }

    func testDashboardPreferencesPersistWithoutNetworkOrSharedStorage() {
        let memory = MemorySecretStore()
        let store = DashboardPreferencesStore(store: memory, account: "dashboard")
        let value = DashboardPreferences(
            sectionOrder: ["signal", "battery"],
            collapsedSections: ["Capabilities"],
            refreshSeconds: 30,
            historyRangeSeconds: 86_400,
            hiddenChartSeries: [
                DashboardChartSeriesID.signalLTE,
                DashboardChartSeriesID.thermal(sensor: "cpu_0"),
            ]
        )
        store.save(value)
        XCTAssertEqual(store.load(), value)
    }

    private func dischargeHistory(
        start: Date,
        minutes: Int,
        currentMA: Int,
        capacityPercent: Int,
        learnedFullCapacityMAh: Int?,
        designCapacityMAh: Int?
    ) -> [TelemetrySample] {
        (0 ... minutes * 2).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 30),
                batteryPercent: capacityPercent,
                batteryState: "Discharging",
                batteryCurrentMa: currentMA,
                batteryLearnedFullCapacityMah: learnedFullCapacityMAh,
                batteryDesignCapacityMah: designCapacityMAh,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }
    }

    func testDashboardPreferencesDecodeExistingValueWithAllChartSeriesVisible() throws {
        let data = Data(
            #"{"sectionOrder":["wifi","thermal"],"collapsedSections":["Wi-Fi"],"refreshSeconds":5,"historyRangeSeconds":86400}"#.utf8
        )
        let value = try JSONDecoder().decode(DashboardPreferences.self, from: data)
        XCTAssertEqual(value.sectionOrder, ["wifi", "thermal"])
        XCTAssertEqual(value.collapsedSections, ["Wi-Fi"])
        XCTAssertEqual(value.refreshSeconds, 5)
        XCTAssertTrue(value.hiddenChartSeries.isEmpty)
    }

    func testWifiConfirmationIdentifierExistsBeforeNetworkMutationAndPersists() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = PendingWifiConfirmation.make(now: now)
        XCTAssertEqual(pending.transactionId.count, 24)
        XCTAssertNotNil(pending.transactionId.range(of: #"^[A-Za-z0-9_-]{24}$"#, options: .regularExpression))
        XCTAssertEqual(pending.expiresAt, now.addingTimeInterval(120))

        let restored = try JSONDecoder().decode(
            PendingWifiConfirmation.self,
            from: JSONEncoder().encode(pending)
        )
        XCTAssertEqual(restored, pending)

        let memory = MemorySecretStore()
        let store = WifiConfirmationStore(store: memory)
        try store.save(pending)
        XCTAssertEqual(try store.load(), pending)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testBase64URLRoundTrip() throws {
        let data = Data(0 ..< 32)
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(try Base64URL.decode(encoded), data)
        XCTAssertThrowsError(try Base64URL.decode("not+url"))
    }

    func testPairingPayloadRequiresFreshFixedLocalHTTPSProfile() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nonce = Base64URL.encode(Data(repeating: 7, count: 32))
        let pin = "sha256/" + Data(repeating: 9, count: 32).base64EncodedString()
        let valid = payloadJSON(
            baseURL: "https://u60.local:19443",
            pin: pin,
            nonce: nonce,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(try PairingPayload.decode(valid, now: now).profile.spkiSHA256, pin)

        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "http://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(120)),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://example.com:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(120)),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now),
            now: now
        ))
        XCTAssertThrowsError(try PairingPayload.decode(
            payloadJSON(baseURL: "https://u60.local:19443", pin: pin, nonce: nonce, expiresAt: now.addingTimeInterval(301)),
            now: now
        ))
    }

    func testLocalNetworkPreflightUsesOnlyTheValidatedPairingEndpoint() throws {
        let profile = try DeviceProfile(
            baseURL: XCTUnwrap(URL(string: "https://192.168.0.1:9443")),
            spkiSHA256: "sha256/" + Data(repeating: 9, count: 32).base64EncodedString()
        )

        XCTAssertEqual(
            try LocalNetworkPreflight.endpoint(for: profile),
            .init(host: "192.168.0.1", port: 9443)
        )
    }

    func testSimulatorCredentialSignsAndPersistsOnlyDeviceLocalMaterial() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        let pending = try credentials.prepareCredential()
        #if targetEnvironment(simulator)
            XCTAssertFalse(pending.secureEnclaveBacked)
        #endif
        let message = Data("u60-test-challenge".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: credentials.sign(message))
        let publicKey = try P256.Signing.PublicKey(derRepresentation: pending.publicKeySPKI)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))

        let profile = try DeviceProfile(
            baseURL: XCTUnwrap(URL(string: "https://u60.local:19443")),
            spkiSHA256: "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        )
        let metadata = try CredentialMetadata(id: "credential_1", label: "Test", secureEnclaveBacked: false)
        try credentials.commit(metadata: metadata, profile: profile)
        XCTAssertEqual(try credentials.metadata(), metadata)
        XCTAssertEqual(try credentials.profile(), profile)
        try credentials.removeLocalCredential()
        XCTAssertNil(try credentials.metadata())
        XCTAssertNil(try credentials.profile())
    }

    func testP256SPKIPinMatchesCryptoKitDER() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        let secKey = try XCTUnwrap(SecKeyCreateWithData(publicKey.x963Representation as CFData, attributes as CFDictionary, &error))
        let expected = "sha256/" + Data(SHA256.hash(data: publicKey.derRepresentation)).base64EncodedString()
        XCTAssertEqual(SPKIPinningDelegate.pin(for: secKey), expected)
    }

    func testPersistedProfileAndCredentialAreRevalidatedOnRead() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        try memory.write(
            Data(#"{"baseURL":"https://example.com:9443","spkiSHA256":"sha256/BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ="}"#.utf8),
            account: "device-profile"
        )
        XCTAssertThrowsError(try credentials.profile())

        try memory.write(
            Data(#"{"id":"../../bad","label":"Test","secureEnclaveBacked":false}"#.utf8),
            account: "credential-metadata"
        )
        XCTAssertThrowsError(try credentials.metadata())
    }

    func testInvalidPersistedSigningKeyCanBeDiscardedAndRecreated() throws {
        let memory = MemorySecretStore()
        let credentials = DeviceCredentialStore(store: memory)
        try memory.write(Data(repeating: 0xFF, count: 19), account: "signing-key")
        XCTAssertThrowsError(try credentials.prepareCredential())

        try credentials.removeLocalCredential()
        let replacement = try credentials.prepareCredential()
        XCTAssertFalse(replacement.publicKeySPKI.isEmpty)
    }

    func testAllHTTPRedirectsAreRejectedBeforeFollowing() throws {
        let pin = "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        let delegate = try SPKIPinningDelegate(expectedPin: pin)
        let sourceURL = try XCTUnwrap(URL(string: "https://u60.local:19443/v1/device"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://u60.local:9090/api/device"]
        ))
        let task = URLSession.shared.dataTask(with: sourceURL)

        for destination in [
            "http://u60.local:9090/api/device",
            "https://example.com:9443/v1/device",
        ] {
            let capture = RedirectCapture()
            let request = try URLRequest(url: XCTUnwrap(URL(string: destination)))
            delegate.urlSession(
                .shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request
            ) { followedRequest in
                capture.record(followedRequest)
            }
            XCTAssertTrue(capture.wasCalled)
            XCTAssertNil(capture.request)
        }
        task.cancel()
    }

    func testMissingServerTrustIsRejectedWithAnExplicitDiagnostic() throws {
        let pin = "sha256/" + Data(repeating: 4, count: 32).base64EncodedString()
        let delegate = try SPKIPinningDelegate(expectedPin: pin)
        let protectionSpace = URLProtectionSpace(
            host: "u60.local",
            port: 9443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let completed = expectation(description: "authentication challenge completed")
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(delegate.consumeTrustFailure(), .missingServerTrust)
    }

    private func payloadJSON(
        baseURL: String,
        pin: String,
        nonce: String,
        expiresAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"version":1,"base_url":"\(baseURL)","spki_sha256":"\(pin)","pairing_nonce":"\(nonce)","expires_at":"\(formatter.string(from: expiresAt))"}
        """
    }
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (called: Bool, request: URLRequest?) = (false, nil)

    var wasCalled: Bool {
        lock.withLock { state.called }
    }

    var request: URLRequest? {
        lock.withLock { state.request }
    }

    func record(_ request: URLRequest?) {
        lock.withLock { state = (true, request) }
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
    func performDefaultHandling(for _: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {}
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
