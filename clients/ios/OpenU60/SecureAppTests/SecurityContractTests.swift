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

    func testDashboardCapabilityPlanDeduplicatesAndSkipsUnsupportedEntries() throws {
        let report = try JSONDecoder().decode(
            Components.Schemas.CapabilityReport.self,
            from: Data(
                #"{"adapter":"b04","firmware_target":"hk_b04","capabilities":[{"id":"wifi_status","status":"available","recovery":{"required":false}},{"id":"wifi_status","status":"degraded","recovery":{"required":false}},{"id":"battery_status","status":"unsupported","recovery":{"required":false}},{"id":"signal_status","status":"available","recovery":{"required":false}}]}"#.utf8
            )
        )

        XCTAssertEqual(
            AgentService.dashboardCapabilityIDs(from: report.capabilities),
            [.wifiStatus, .signalStatus]
        )
    }

    func testDashboardRequestSchedulerOverlapsWorkWithinFixedLimit() async throws {
        let probe = ConcurrentOperationProbe()
        let values = Array(0 ..< 12)
        let results = try await DashboardRequestScheduler.run(values) { value in
            await probe.begin()
            do {
                try await Task.sleep(for: .milliseconds(20))
                await probe.end()
                return value
            } catch {
                await probe.end()
                throw error
            }
        }

        XCTAssertEqual(results.sorted(), values)
        let maximumActive = await probe.maximumActive
        XCTAssertGreaterThan(maximumActive, 1)
        XCTAssertLessThanOrEqual(maximumActive, DashboardRequestScheduler.maximumConcurrentRequests)
    }

    func testDashboardRequestSchedulerPropagatesCancellation() async throws {
        let task = Task {
            try await DashboardRequestScheduler.run(Array(0 ..< 8)) { value in
                try await Task.sleep(for: .seconds(30))
                return value
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled dashboard requests must not complete successfully")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testWrappedWifiFeaturesDecodeFailureReportsAgentReleaseMismatch() throws {
        let key = try XCTUnwrap(TestCodingKey(stringValue: "features"))
        let decodingError = DecodingError.keyNotFound(
            key,
            .init(codingPath: [], debugDescription: "Required Wi-Fi features are missing")
        )
        let clientError = ClientError(
            operationID: "getWifiStatus",
            operationInput: "test",
            causeDescription: "response body decoding failed",
            underlyingError: decodingError
        )

        XCTAssertEqual(
            AgentService.dashboardFailureMessage(for: .wifiStatus, error: clientError),
            String(
                localized: "The running agent does not provide the required Wi-Fi feature fields. Update it to the same release as this app."
            )
        )
        XCTAssertNotEqual(
            AgentService.dashboardFailureMessage(for: .signalStatus, error: clientError),
            String(
                localized: "The running agent does not provide the required Wi-Fi feature fields. Update it to the same release as this app."
            )
        )
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
            timestamp: start.addingTimeInterval(30),
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
            timestamp: start.addingTimeInterval(60),
            batteryPercent: 78,
            lteRSRPdBm: -92,
            nr5gRSRPdBm: -89,
            wifiSignalDbm: -53,
            thermalTemperaturesC: ["cpu_0": 44]
        )

        var history = store.append(first, to: [])
        history = store.append(replacement, to: history)
        let anchoredReplacement = TelemetrySample(
            timestamp: start,
            batteryPercent: replacement.batteryPercent,
            lteRSRPdBm: replacement.lteRSRPdBm,
            nr5gRSRPdBm: replacement.nr5gRSRPdBm,
            wifiSignalDbm: replacement.wifiSignalDbm,
            thermalTemperaturesC: replacement.thermalTemperaturesC,
            cpuUsagePercent: replacement.cpuUsagePercent,
            memoryUsedPercent: replacement.memoryUsedPercent,
            storageUsedPercent: replacement.storageUsedPercent
        )
        XCTAssertEqual(history, [anchoredReplacement])
        history = store.append(later, to: history)
        XCTAssertEqual(history, [anchoredReplacement, later])
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
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil,
                wifiSignalDbm: 1,
                thermalTemperaturesC: temperatures.merging(["invalid": .infinity]) { current, _ in current }
            ),
            to: []
        )
        XCTAssertEqual(history.first?.thermalTemperaturesC.count, TelemetryHistoryStore.maximumThermalSeries)
        XCTAssertNil(history.first?.thermalTemperaturesC["invalid"])
        XCTAssertNil(history.first?.wifiSignalDbm)
    }

    func testTelemetryHistoryCoversSevenDaysAtMinuteSpacingAndStaysBounded() throws {
        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let count = TelemetryHistoryStore.maximumSamples + 5
        let samples = (0 ..< count).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * TelemetryHistoryStore.minimumSpacing),
                batteryPercent: 50,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil,
                cpuUsagePercent: index == count - 1 ? -1 : 25,
                memoryUsedPercent: 50,
                storageUsedPercent: index == count - 1 ? 101 : 75
            )
        }
        try memory.write(JSONEncoder().encode(samples), account: "history")
        let now = try XCTUnwrap(samples.last?.timestamp)
        let loaded = store.load(now: now)

        XCTAssertEqual(loaded.count, TelemetryHistoryStore.maximumSamples)
        XCTAssertGreaterThanOrEqual(
            loaded.first?.timestamp ?? .distantPast,
            now.addingTimeInterval(-TelemetryHistoryStore.retention)
        )
        XCTAssertTrue(zip(loaded, loaded.dropFirst()).allSatisfy { pair in
            pair.1.timestamp.timeIntervalSince(pair.0.timestamp) >= TelemetryHistoryStore.minimumSpacing
        })
        XCTAssertNil(loaded.last?.cpuUsagePercent)
        XCTAssertNil(loaded.last?.storageUsedPercent)
        XCTAssertEqual(loaded.last?.memoryUsedPercent, 50)
    }

    func testTelemetryHistoryMigratesLegacyTenSecondSamplesToMinuteSpacing() throws {
        let memory = MemorySecretStore()
        let store = TelemetryHistoryStore(store: memory, account: "history")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = (0 ..< 13).map { index in
            TelemetrySample(
                timestamp: start.addingTimeInterval(Double(index) * 10),
                batteryPercent: 50 + index,
                lteRSRPdBm: nil,
                nr5gRSRPdBm: nil
            )
        }
        try memory.write(JSONEncoder().encode(legacy), account: "history")

        let loaded = store.load(now: start.addingTimeInterval(120))
        XCTAssertEqual(loaded.map(\.timestamp), [start, start.addingTimeInterval(60), start.addingTimeInterval(120)])
        XCTAssertEqual(loaded.map(\.batteryPercent), [55, 61, 62])

        let migratedData = try XCTUnwrap(try memory.read(account: "history"))
        XCTAssertEqual(try JSONDecoder().decode([TelemetrySample].self, from: migratedData), loaded)
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

    func testDashboardPreferencesPersistWithoutNetworkOrSharedStorage() {
        let memory = MemorySecretStore()
        let store = DashboardPreferencesStore(store: memory, account: "dashboard")
        let value = DashboardPreferences(
            sectionOrder: ["signal", "battery"],
            collapsedSections: ["Capabilities"],
            refreshSeconds: 30,
            historyRangeSeconds: 604_800,
            hiddenChartSeries: [
                DashboardChartSeriesID.signalLTE,
                DashboardChartSeriesID.thermal(sensor: "cpu_0"),
            ]
        )
        store.save(value)
        XCTAssertEqual(store.load(), value)
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

private struct TestCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
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

private actor ConcurrentOperationProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }
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
