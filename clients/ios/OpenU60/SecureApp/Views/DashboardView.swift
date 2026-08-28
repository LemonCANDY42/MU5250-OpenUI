import Charts
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable, Codable {
    case device, capabilities, system, battery, thermal, signal, cellular, traffic, wifi, lanClients, messages

    var id: Self { self }

    var title: LocalizedStringKey {
        LocalizedStringKey(titleText)
    }

    var titleText: String {
        switch self {
        case .device: "Device"
        case .capabilities: "Capabilities"
        case .system: "System status"
        case .battery: "Battery"
        case .thermal: "Thermal"
        case .signal: "Signal strength"
        case .cellular: "Cellular information"
        case .traffic: "Traffic"
        case .wifi: "Wi-Fi information"
        case .lanClients: "LAN clients"
        case .messages: "Messages"
        }
    }

    var capabilityID: Components.Schemas.Capability.IdPayload? {
        switch self {
        case .device: .deviceIdentity
        case .capabilities: nil
        case .system: .systemStatus
        case .battery: .batteryStatus
        case .thermal: .thermalStatus
        case .signal: .signalStatus
        case .cellular: .cellularStatus
        case .traffic: .trafficStatus
        case .wifi: .wifiStatus
        case .lanClients: .lanClients
        case .messages: .smsList
        }
    }

    var icon: String {
        switch self {
        case .device: "wifi.router.fill"
        case .capabilities: "checklist"
        case .system: "cpu"
        case .battery: "battery.100"
        case .thermal: "thermometer.medium"
        case .signal: "antenna.radiowaves.left.and.right"
        case .cellular: "cellularbars"
        case .traffic: "arrow.up.arrow.down"
        case .wifi: "wifi"
        case .lanClients: "laptopcomputer.and.iphone"
        case .messages: "message.fill"
        }
    }

    static func canonicalCollapseID(for storedValue: String) -> String {
        if allCases.contains(where: { $0.rawValue == storedValue }) {
            return storedValue
        }
        let legacyValues: [String: Self] = [
            "U60 Pro": .device,
            "MU5250": .device,
            "Capabilities": .capabilities,
            "System status": .system,
            "Battery": .battery,
            "Thermal": .thermal,
            "Signal": .signal,
            "Cellular": .cellular,
            "Traffic": .traffic,
            "Wi-Fi": .wifi,
            "LAN clients": .lanClients,
            "Messages": .messages,
        ]
        return legacyValues[storedValue]?.rawValue ?? storedValue
    }
}

private enum TelemetryRange: Int, CaseIterable, Identifiable {
    case hour = 3_600
    case sixHours = 21_600
    case day = 86_400

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        }
    }
}

private struct DashboardChartSeries: Identifiable {
    let id: String
    let label: String
}

private struct DashboardTelemetrySeries: Identifiable {
    let id: String
    let label: String
    let segments: [TelemetryChartSegment]
}

struct DashboardView: View {
    let model: AppModel
    @State private var sectionOrder = DashboardSection.allCases
    @State private var collapsedSections = Set<String>()
    @State private var refreshSeconds = 0
    @State private var historyRangeSeconds = TelemetryRange.day.rawValue
    @State private var hiddenChartSeries = Set<String>()
    @State private var showsLayoutEditor = false
    private let preferencesStore = DashboardPreferencesStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = model.dashboard {
                    LazyVStack(spacing: 14) {
                        ForEach(visibleSections(in: snapshot)) { section in
                            dashboardSection(section, snapshot: snapshot)
                        }
                        ForEach(
                            snapshot.failures
                                .filter { Components.Schemas.Capability.IdPayload(rawValue: $0.key) == nil }
                                .sorted(by: { $0.key < $1.key }),
                            id: \.key
                        ) { key, message in
                            statusCard(
                                id: "failure.\(key)",
                                title: key,
                                icon: "exclamationmark.triangle.fill",
                                tint: .orange
                            ) {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("No status yet", systemImage: "wifi.router")
                        .padding(.top, 80)
                }
            }
            .background(Color(.systemGroupedBackground))
            .connectionIssueInset(model.connectionIssue)
            .navigationTitle("Dashboard")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Refresh frequency", selection: $refreshSeconds) {
                            Text("Manual only").tag(0)
                            Text("Every 2 seconds").tag(2)
                            Text("Every 5 seconds").tag(5)
                            Text("Every 15 seconds").tag(15)
                            Text("Every 30 seconds").tag(30)
                            Text("Every minute").tag(60)
                        }
                        Picker("Chart range", selection: $historyRangeSeconds) {
                            ForEach(TelemetryRange.allCases) { range in
                                Text(range.title).tag(range.rawValue)
                            }
                        }
                    } label: {
                        Label {
                            Text("Monitoring")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label {
                            Text("Refresh now")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.pulse, options: .repeating, isActive: model.isWorking)
                        }
                    }
                    .disabled(model.isWorking)
                    Button {
                        showsLayoutEditor = true
                    } label: {
                        Label("Arrange dashboard", systemImage: "arrow.up.arrow.down.square")
                    }
                }
            }
            .onAppear(perform: restoreLayout)
            .onChange(of: refreshSeconds) { persistPreferences() }
            .onChange(of: historyRangeSeconds) { persistPreferences() }
            .task(id: refreshSeconds) {
                guard refreshSeconds > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(refreshSeconds))
                    guard !Task.isCancelled else { return }
                    await model.refresh()
                }
            }
            .sheet(isPresented: $showsLayoutEditor) {
                NavigationStack {
                    List {
                        Section {
                            ForEach(sectionOrder) { section in
                                Label(section.title, systemImage: section.icon)
                            }
                            .onMove(perform: moveSections)
                        } footer: {
                            Text("Unavailable cards stay in your layout and can still be reordered.")
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .navigationTitle("Arrange dashboard")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsLayoutEditor = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func dashboardSection(_ section: DashboardSection, snapshot: DashboardSnapshot) -> some View {
        switch section {
        case .device:
            if let value = snapshot.device {
                deviceCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .capabilities: capabilityCard(snapshot.report)
        case .system:
            if let value = snapshot.system {
                systemCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .battery:
            if let value = snapshot.battery {
                batteryCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .thermal:
            if let value = snapshot.thermal {
                thermalCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .signal:
            if snapshot.signal != nil || snapshot.wifi != nil {
                signalStrengthCard(signal: snapshot.signal, wifi: snapshot.wifi)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .cellular:
            if snapshot.cellular != nil || snapshot.signal != nil {
                cellularInformationCard(cellular: snapshot.cellular, signal: snapshot.signal)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .traffic:
            if let value = snapshot.traffic {
                trafficCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .wifi:
            if let value = snapshot.wifi {
                wifiCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .lanClients:
            if let value = snapshot.lanClients {
                lanClientsCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        case .messages:
            if let value = snapshot.sms {
                smsCard(value)
            } else {
                unavailableCard(for: section, message: failureMessage(for: section, in: snapshot))
            }
        }
    }

    private func deviceCard(_ device: Components.Schemas.Device) -> some View {
        statusCard(
            id: DashboardSection.device.rawValue,
            title: device.model,
            icon: "wifi.router.fill",
            tint: .blue
        ) {
            Text(device.firmwareVersion ?? device.firmwareTarget)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("\(device.manufacturer) · \(device.adapter)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func capabilityCard(_ report: Components.Schemas.CapabilityReport) -> some View {
        statusCard(id: DashboardSection.capabilities.rawValue, title: "Capabilities", icon: "checklist", tint: .indigo) {
            ForEach(report.capabilities, id: \.id) { capability in
                HStack {
                    Text(capabilityLabel(capability.id))
                    Spacer()
                    Label(
                        capabilityStatusLabel(capability.status),
                        systemImage: capabilityStatusIcon(capability.status)
                    )
                    .font(.caption)
                    .foregroundStyle(capabilityStatusColor(capability.status))
                }
                if let reason = capability.reason, !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func systemCard(_ system: Components.Schemas.SystemStatus) -> some View {
        let cpuSegments = telemetrySegments(\TelemetrySample.cpuUsagePercent)
        let memorySegments = telemetrySegments(\TelemetrySample.memoryUsedPercent)
        let storageSegments = telemetrySegments(\TelemetrySample.storageUsedPercent)
        let historyPointCount = max(
            cpuSegments.reduce(0) { $0 + $1.points.count },
            memorySegments.reduce(0) { $0 + $1.points.count },
            storageSegments.reduce(0) { $0 + $1.points.count }
        )
        return statusCard(id: DashboardSection.system.rawValue, title: "System status", icon: "cpu", tint: .purple) {
            metric("Uptime", formatDuration(system.uptimeSeconds))
            metric("Load", system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            metric("Kernel", system.kernel)
            if let cpu = system.cpuUsagePercent {
                metric("CPU usage", formatPercent(cpu))
            }
            if let total = system.memoryTotalMb,
               let available = system.memoryAvailableMb,
               let used = system.memoryUsedPercent
            {
                metric("Memory used", formatPercent(used))
                metric("Memory available", "\(available) / \(total) MiB")
            }
            if let total = system.storageTotalMb,
               let available = system.storageAvailableMb,
               let used = system.storageUsedPercent
            {
                metric("/data storage used", formatPercent(used))
                metric("/data storage available", "\(available) / \(total) MiB")
            }
            if historyPointCount >= 2 {
                Divider()
                chartHeader(
                    title: "System utilization history",
                    accessibilityLabel: "Choose system chart series",
                    series: systemChartSeries
                )
                let showsCPU = !hiddenChartSeries.contains(DashboardChartSeriesID.systemCPU)
                let showsMemory = !hiddenChartSeries.contains(DashboardChartSeriesID.systemMemory)
                let showsStorage = !hiddenChartSeries.contains(DashboardChartSeriesID.systemStorage)
                if !showsCPU, !showsMemory, !showsStorage {
                    Text("No chart series selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Chart {
                        if showsCPU {
                            ForEach(cpuSegments) { segment in
                                let seriesKey = segmentSeriesKey("cpu", segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Utilization percentage", point.value),
                                        series: .value(
                                            "System metric segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "CPU")
                                    ))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Utilization percentage"), point.value)
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "CPU")
                                    ))
                                }
                            }
                        }
                        if showsMemory {
                            ForEach(memorySegments) { segment in
                                let seriesKey = segmentSeriesKey("memory", segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Utilization percentage", point.value),
                                        series: .value(
                                            "System metric segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "Memory")
                                    ))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Utilization percentage"), point.value)
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "Memory")
                                    ))
                                }
                            }
                        }
                        if showsStorage {
                            ForEach(storageSegments) { segment in
                                let seriesKey = segmentSeriesKey("storage", segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Utilization percentage", point.value),
                                        series: .value(
                                            "System metric segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "Storage")
                                    ))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Utilization percentage"), point.value)
                                    )
                                    .foregroundStyle(by: .value(
                                        String(localized: "System metric"),
                                        String(localized: "Storage")
                                    ))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: telemetryWindow)
                    .chartYScale(domain: 0 ... 100)
                    .chartForegroundStyleScale([
                        String(localized: "CPU"): Color.purple,
                        String(localized: "Memory"): Color.blue,
                        String(localized: "Storage"): Color.orange,
                    ])
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 190)
                    .accessibilityLabel(Text("System utilization history"))
                    .accessibilityValue(Text(systemChartAccessibilitySummary(
                        system,
                        showsCPU: showsCPU,
                        showsMemory: showsMemory,
                        showsStorage: showsStorage
                    )))
                }
            }
        }
    }

    private func batteryCard(_ battery: Components.Schemas.BatteryStatus) -> some View {
        let batterySegments = telemetrySegments { sample in
            sample.batteryPercent.map(Double.init)
        }
        let batteryPointCount = batterySegments.reduce(0) { $0 + $1.points.count }
        return statusCard(
            id: DashboardSection.battery.rawValue,
            title: "Battery",
            icon: batteryIcon(battery.capacityPercent),
            tint: batteryColor(battery.capacityPercent)
        ) {
            metric("Capacity", "\(battery.capacityPercent)%")
            metric("State", localizedBatteryState(battery.state))
            metric("Voltage", String(format: "%.3f V", Double(battery.voltageMv) / 1000))
            metric("Current", "\(battery.currentMa) mA")
            metric("Power", String(format: "%.2f W", Double(battery.powerMw).magnitude / 1000))
            metric("Temperature", String(format: "%.1f °C", battery.temperatureC))
            if let healthPercent = batteryCapacityHealthPercent(
                learnedFullCapacityMah: battery.learnedFullCapacityMah,
                designCapacityMah: battery.designCapacityMah
            ) {
                metric("Battery health", formatPercent(healthPercent))
            }
            if let health = battery.health {
                metric("Reported condition", localizedBatteryHealth(health))
            }
            if let cycles = battery.cycleCount {
                metric("Cycle count", cycles.formatted())
            }
            if let capacity = battery.learnedFullCapacityMah {
                metric("Learned full capacity", "\(capacity) mAh")
            }
            if let capacity = battery.designCapacityMah {
                metric("Design capacity", "\(capacity) mAh")
            }
            if let counter = battery.chargeCounterMah {
                metric("Relative charge counter", "\(counter) mAh")
                Text("The relative charge counter is a signed kernel fuel-gauge value, not remaining capacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let seconds = battery.timeToEmptySeconds {
                metric("Kernel estimate to empty", formatBatteryEstimate(seconds, zeroLabel: "Empty"))
            }
            if let seconds = battery.timeToFullSeconds {
                metric("Kernel estimate to full", formatBatteryEstimate(seconds, zeroLabel: "Complete"))
            }
            if batteryPointCount >= 2 {
                Divider()
                Text("Battery history").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(batterySegments) { segment in
                        let seriesKey = segmentSeriesKey("battery", segment)
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Battery level", point.value),
                                series: .value(
                                    "Battery segment",
                                    seriesKey
                                )
                            )
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)
                        }
                        if segment.points.count == 1, let point = segment.points.first {
                            PointMark(
                                x: .value(String(localized: "Time"), point.timestamp),
                                y: .value(String(localized: "Battery level"), point.value)
                            )
                            .foregroundStyle(.green)
                        }
                    }
                }
                .chartXScale(domain: telemetryWindow)
                .chartYScale(domain: 0 ... 100)
                .frame(height: 150)
            }
        }
    }

    private func thermalCard(_ thermal: Components.Schemas.ThermalStatus) -> some View {
        let series = thermalChartSeries(current: thermal)
        let samples = visibleTelemetry.filter { !$0.thermalTemperaturesC.isEmpty }
        let visibleSeries = series.filter { !hiddenChartSeries.contains($0.id) }
        let chartSeries = visibleSeries.map { item in
            DashboardTelemetrySeries(
                id: item.id,
                label: item.label,
                segments: telemetrySegments { sample in
                    sample.thermalTemperaturesC[thermalSensorID(for: item.id)]
                }
            )
        }
        return statusCard(id: DashboardSection.thermal.rawValue, title: "Thermal", icon: "thermometer.medium", tint: .orange) {
            if thermal.sensors.isEmpty {
                Text("No sensors reported").foregroundStyle(.secondary)
            } else {
                ForEach(thermal.sensors, id: \.sensor) { sensor in
                    metricVerbatim(thermalSensorLabel(sensor.sensor), String(format: "%.1f °C", sensor.temperatureC))
                }
            }
            if samples.count >= 2, !series.isEmpty {
                Divider()
                chartHeader(
                    title: "Thermal history",
                    accessibilityLabel: "Choose thermal chart series",
                    series: series
                )
                if visibleSeries.isEmpty {
                    Text("No chart series selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Chart {
                        ForEach(chartSeries) { item in
                            ForEach(item.segments) { segment in
                                let seriesKey = segmentSeriesKey(item.id, segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Sensor temperature", point.value),
                                        series: .value(
                                            "Sensor segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Sensor"), item.label))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Sensor temperature"), point.value)
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Sensor"), item.label))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: telemetryWindow)
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 200)
                }
            }
        }
    }

    private func signalStrengthCard(
        signal: Components.Schemas.SignalStatus?,
        wifi: Components.Schemas.WifiStatus?
    ) -> some View {
        let wifiSegments = telemetrySegments(\TelemetrySample.wifiSignalDbm)
        let lteSegments = telemetrySegments(\TelemetrySample.lteRSRPdBm)
        let nr5gSegments = telemetrySegments(\TelemetrySample.nr5gRSRPdBm)
        let wifiPointCount = wifiSegments.reduce(0) { $0 + $1.points.count }
        let cellularPointCount = max(
            lteSegments.reduce(0) { $0 + $1.points.count },
            nr5gSegments.reduce(0) { $0 + $1.points.count }
        )
        return statusCard(
            id: DashboardSection.signal.rawValue,
            title: "Signal strength",
            icon: "antenna.radiowaves.left.and.right",
            tint: .cyan
        ) {
            Text("Wi-Fi signal")
                .font(.subheadline.weight(.semibold))
            if let link = wifi?.currentClientLink {
                metric("Signal", "\(link.signalDbm) dBm")
                metric("Observed band", link.band)
            } else {
                Text("Not currently observed by the U60")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if wifiPointCount >= 2 {
                Divider()
                chartHeader(
                    title: "Wi-Fi signal history",
                    accessibilityLabel: "Choose Wi-Fi signal chart series",
                    series: wifiSignalChartSeries
                )
                if hiddenChartSeries.contains(DashboardChartSeriesID.signalWiFi) {
                    Text("No chart series selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Chart {
                        ForEach(wifiSegments) { segment in
                            let seriesKey = segmentSeriesKey("wifi", segment)
                            ForEach(segment.points) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Wi-Fi signal strength", point.value),
                                    series: .value(
                                        "Wi-Fi signal segment",
                                        seriesKey
                                    )
                                )
                                .foregroundStyle(.indigo)
                                .interpolationMethod(.monotone)
                            }
                            if segment.points.count == 1, let point = segment.points.first {
                                PointMark(
                                    x: .value(String(localized: "Time"), point.timestamp),
                                    y: .value(String(localized: "Wi-Fi signal strength"), point.value)
                                )
                                .foregroundStyle(.indigo)
                            }
                        }
                    }
                    .chartXScale(domain: telemetryWindow)
                    .frame(height: 170)
                }
            }

            Divider()
            Text("Cellular signal")
                .font(.subheadline.weight(.semibold))
            if let signal {
                metric("Strength", "\(signal.bars) / 5")
                if let lte = signal.lte {
                    metric("LTE RSRP", formatMetric(lte.rsrpDbm, unit: "dBm"))
                }
                if let nr5g = signal.nr5g {
                    metric("5G RSRP", formatMetric(nr5g.rsrpDbm, unit: "dBm"))
                }
            } else {
                Text("Cellular signal unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if cellularPointCount >= 2 {
                Divider()
                chartHeader(
                    title: "Cellular signal history",
                    accessibilityLabel: "Choose cellular signal chart series",
                    series: signalChartSeries
                )
                let showsLTE = !hiddenChartSeries.contains(DashboardChartSeriesID.signalLTE)
                let shows5G = !hiddenChartSeries.contains(DashboardChartSeriesID.signal5G)
                if !showsLTE, !shows5G {
                    Text("No chart series selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Chart {
                        if showsLTE {
                            ForEach(lteSegments) { segment in
                                let seriesKey = segmentSeriesKey("lte", segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Cellular signal strength", point.value),
                                        series: .value(
                                            "Radio segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Radio"), "LTE"))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Cellular signal strength"), point.value)
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Radio"), "LTE"))
                                }
                            }
                        }
                        if shows5G {
                            ForEach(nr5gSegments) { segment in
                                let seriesKey = segmentSeriesKey("5g", segment)
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Cellular signal strength", point.value),
                                        series: .value(
                                            "Radio segment",
                                            seriesKey
                                        )
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Radio"), "5G"))
                                    .interpolationMethod(.monotone)
                                }
                                if segment.points.count == 1, let point = segment.points.first {
                                    PointMark(
                                        x: .value(String(localized: "Time"), point.timestamp),
                                        y: .value(String(localized: "Cellular signal strength"), point.value)
                                    )
                                    .foregroundStyle(by: .value(String(localized: "Radio"), "5G"))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: telemetryWindow)
                    .chartForegroundStyleScale(["LTE": Color.blue, "5G": Color.purple])
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 180)
                }
            }
        }
    }

    private func cellularInformationCard(
        cellular: Components.Schemas.CellularStatus?,
        signal: Components.Schemas.SignalStatus?
    ) -> some View {
        statusCard(
            id: DashboardSection.cellular.rawValue,
            title: "Cellular information",
            icon: "cellularbars",
            tint: .green
        ) {
            if let signal {
                metric("Network", signal.networkType)
                metric("Provider", signal.provider ?? String(localized: "Not reported"))
                metric("Roaming", signal.roaming ? String(localized: "Yes") : String(localized: "No"))
                metric("Active band", signal.activeBand ?? String(localized: "Not reported"))
                if let mode = signal.networkSelectionMode {
                    metric("Network selection", localizedNetworkSelection(mode.rawValue))
                }
                if let aggregation = signal.lteCarrierAggregation {
                    metric("LTE aggregation", aggregationLabel(aggregation))
                }
                if let aggregation = signal.nr5gCarrierAggregation {
                    metric("5G aggregation", aggregationLabel(aggregation))
                }
                if let cellLock = signal.cellLock {
                    metric("LTE cell lock", cellLock.lte ? String(localized: "Configured") : String(localized: "Off"))
                    metric("5G cell lock", cellLock.nr5g ? String(localized: "Configured") : String(localized: "Off"))
                }
                if let lte = signal.lte {
                    metric("LTE band", lte.band ?? String(localized: "Not reported"))
                    metric("LTE RSRQ", formatMetric(lte.rsrqDb, unit: "dB"))
                    metric("LTE SNR", formatMetric(lte.snrDb, unit: "dB"))
                }
                if let nr5g = signal.nr5g {
                    metric("5G band", nr5g.band ?? String(localized: "Not reported"))
                    metric("5G channel", nr5g.channel.map(String.init) ?? String(localized: "Not reported"))
                    metric("5G PCI", nr5g.pci.map(String.init) ?? String(localized: "Not reported"))
                    metric("5G RSRQ", formatMetric(nr5g.rsrqDb, unit: "dB"))
                    metric("5G SNR", formatMetric(nr5g.snrDb, unit: "dB"))
                }
            }
            if let cellular {
                if signal != nil { Divider() }
                Text("Connection")
                    .font(.subheadline.weight(.semibold))
                metric("State", cellular.connected ? String(localized: "Connected") : String(localized: "Disconnected"))
                metric("Protocol", cellular._protocol)
                metric("Interface", cellular.interface ?? String(localized: "Not reported"))
                metric("Uptime", formatDuration(cellular.uptimeSeconds))
                metric("IPv4", cellular.ipv4Addresses.joined(separator: ", ").nilIfEmpty ?? String(localized: "None"))
                metric("IPv6", cellular.ipv6Addresses.joined(separator: ", ").nilIfEmpty ?? String(localized: "None"))
            }
        }
    }

    private func trafficCard(_ traffic: Components.Schemas.TrafficStatus) -> some View {
        statusCard(id: DashboardSection.traffic.rawValue, title: "Traffic", icon: "arrow.up.arrow.down", tint: .blue) {
            metric("Today", formatTraffic(traffic.day))
            metric("Billing cycle", formatTraffic(traffic.cycle))
            metric("Since power-on", formatTraffic(traffic.sincePowerOn))
            metric("All time", formatTraffic(traffic.total))
            metric(
                "Cycle reset",
                traffic.resetEnabled
                    ? String(localized: "Day \(traffic.resetDay)")
                    : String(localized: "Disabled")
            )
        }
    }

    private func wifiCard(_ wifi: Components.Schemas.WifiStatus) -> some View {
        statusCard(id: DashboardSection.wifi.rawValue, title: "Wi-Fi information", icon: "wifi", tint: .indigo) {
            metric("Overall", wifi.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
            metric("Wi-Fi 7", wifi.features.wifi7Active ? String(localized: "Active") : String(localized: "Inactive"))
            metric(
                "MLO",
                wifi.features.mloSupported
                    ? (wifi.features.mloEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    : String(localized: "Not supported on this B04")
            )
            metric(
                "Band steering",
                wifi.features.bandSteeringSupported
                    ? (wifi.features.bandSteeringEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    : String(localized: "Unavailable")
            )
            ForEach(wifi.bands, id: \.band) { band in
                Divider()
                Text(band.band).font(.subheadline.weight(.semibold))
                metric("Network", band.enabled ? band.ssid : String(localized: "Disabled"))
                metric("Radio", "\(band.channel) · \(band.bandwidth)")
                metric("Security", "\(band.encryption)\(band.hidden ? " \(String(localized: "(Hidden)"))" : "")")
                metric("Clients", band.clients.map(String.init) ?? String(localized: "Not reported"))
            }
            if let link = wifi.currentClientLink {
                Divider()
                Text("Current iPhone link")
                    .font(.subheadline.weight(.semibold))
                Text("Measured by the U60 for this authenticated client.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                metric("Band", link.band)
                metric("TX rate", String(format: "%.1f Mbps", link.txBitrateMbps))
                metric("RX rate", String(format: "%.1f Mbps", link.rxBitrateMbps))
                if let throughput = link.expectedThroughputMbps {
                    metric("Expected throughput", String(format: "%.1f Mbps", throughput))
                }
                metric("Connected", formatDuration(link.connectedSeconds))
            }
        }
    }

    private func unavailableCard(for section: DashboardSection, message: String?) -> some View {
        statusCard(
            id: section.rawValue,
            title: section.titleText,
            icon: section == .wifi ? "wifi.exclamationmark" : "exclamationmark.triangle.fill",
            tint: .orange
        ) {
            Text("Status unavailable")
                .font(.subheadline.weight(.semibold))
            Text(message ?? String(localized: "Refresh to try again."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if section == .wifi {
                Text("The app keeps required Wi-Fi fields strict. Refresh after the running agent is updated to the same release as this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func visibleSections(in snapshot: DashboardSnapshot) -> [DashboardSection] {
        sectionOrder.filter { section in
            guard let capabilityID = section.capabilityID else { return true }
            return hasValue(for: section, in: snapshot) || snapshot.report.capabilities.contains { capability in
                capability.id == capabilityID && (capability.status == .available || capability.status == .degraded)
            }
        }
    }

    private func hasValue(for section: DashboardSection, in snapshot: DashboardSnapshot) -> Bool {
        switch section {
        case .device: snapshot.device != nil
        case .capabilities: true
        case .system: snapshot.system != nil
        case .battery: snapshot.battery != nil
        case .thermal: snapshot.thermal != nil
        case .signal: snapshot.signal != nil || snapshot.wifi != nil
        case .cellular: snapshot.cellular != nil || snapshot.signal != nil
        case .traffic: snapshot.traffic != nil
        case .wifi: snapshot.wifi != nil
        case .lanClients: snapshot.lanClients != nil
        case .messages: snapshot.sms != nil
        }
    }

    private func failureMessage(for section: DashboardSection, in snapshot: DashboardSnapshot) -> String? {
        guard let failureKey = section.capabilityID?.rawValue else { return nil }
        return snapshot.failures[failureKey]
    }

    private func lanClientsCard(_ value: Components.Schemas.LanClients) -> some View {
        statusCard(
            id: DashboardSection.lanClients.rawValue,
            title: "LAN clients",
            icon: "laptopcomputer.and.iphone",
            tint: .teal
        ) {
            if value.clients.isEmpty {
                Text("No current DHCP clients").foregroundStyle(.secondary)
            } else {
                ForEach(value.clients, id: \.macAddress) { client in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.hostname.nilIfEmpty ?? client.macAddress)
                            .font(.subheadline.weight(.medium))
                        Text("\(client.ipv4Address) · \(client.macAddress)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func smsCard(_ value: Components.Schemas.SmsPage) -> some View {
        statusCard(id: DashboardSection.messages.rawValue, title: "Messages", icon: "message.fill", tint: .mint) {
            if value.messages.isEmpty {
                Text("No SMS messages").foregroundStyle(.secondary)
            } else {
                ForEach(value.messages.prefix(20), id: \.id) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(message.sender).font(.subheadline.weight(.medium))
                            Spacer()
                            if !message.read {
                                Text("Unread").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                        Text(message.timestamp).font(.caption2).foregroundStyle(.secondary)
                        Text(message.content).font(.footnote).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func statusCard(
        id: String,
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        CardView {
            DisclosureGroup(isExpanded: expansionBinding(for: id)) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label {
                    Text(LocalizedStringKey(title))
                } icon: {
                    Image(systemName: icon)
                }
                .font(.headline)
                .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var signalChartSeries: [DashboardChartSeries] {
        [
            DashboardChartSeries(id: DashboardChartSeriesID.signalLTE, label: "LTE"),
            DashboardChartSeries(id: DashboardChartSeriesID.signal5G, label: "5G"),
        ]
    }

    private var wifiSignalChartSeries: [DashboardChartSeries] {
        [
            DashboardChartSeries(
                id: DashboardChartSeriesID.signalWiFi,
                label: String(localized: "Wi-Fi")
            ),
        ]
    }

    private var systemChartSeries: [DashboardChartSeries] {
        [
            DashboardChartSeries(id: DashboardChartSeriesID.systemCPU, label: String(localized: "CPU")),
            DashboardChartSeries(id: DashboardChartSeriesID.systemMemory, label: String(localized: "Memory")),
            DashboardChartSeries(id: DashboardChartSeriesID.systemStorage, label: String(localized: "Storage")),
        ]
    }

    private func thermalChartSeries(current: Components.Schemas.ThermalStatus) -> [DashboardChartSeries] {
        var sensorIDs = Set(current.sensors.map(\.sensor))
        for sample in model.telemetryHistory {
            sensorIDs.formUnion(sample.thermalTemperaturesC.keys)
        }
        return sensorIDs.sorted().map { sensor in
            DashboardChartSeries(
                id: DashboardChartSeriesID.thermal(sensor: sensor),
                label: thermalSensorLabel(sensor)
            )
        }
    }

    private func thermalSensorID(for seriesID: String) -> String {
        String(seriesID.dropFirst(DashboardChartSeriesID.thermalPrefix.count))
    }

    private func thermalSensorLabel(_ sensor: String) -> String {
        switch sensor {
        case "cpu_0": String(localized: "CPU 1")
        case "cpu_1": String(localized: "CPU 2")
        case "cpu_2": String(localized: "CPU 3")
        case "cpu_3": String(localized: "CPU 4")
        case "modem": String(localized: "Modem")
        case "battery": String(localized: "Battery")
        case "usb": "USB"
        default: sensor
        }
    }

    private func chartHeader(
        title: LocalizedStringKey,
        accessibilityLabel: LocalizedStringKey,
        series: [DashboardChartSeries]
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                ForEach(series) { item in
                    Toggle(isOn: chartSeriesVisibilityBinding(for: item.id)) {
                        Text(item.label)
                    }
                }
            } label: {
                Label("Chart series", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel(Text(accessibilityLabel))
        }
    }

    private func chartSeriesVisibilityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenChartSeries.contains(id) },
            set: { isVisible in
                if isVisible {
                    hiddenChartSeries.remove(id)
                } else {
                    hiddenChartSeries.insert(id)
                }
                persistPreferences()
            }
        )
    }

    private var visibleTelemetry: [TelemetrySample] {
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(historyRangeSeconds))
        return model.telemetryHistory.filter { $0.timestamp >= cutoff }
    }

    private var telemetryWindow: ClosedRange<Date> {
        let now = Date.now
        return now.addingTimeInterval(-TimeInterval(historyRangeSeconds)) ... now
    }

    private func telemetrySegments(
        _ value: (TelemetrySample) -> Double?
    ) -> [TelemetryChartSegment] {
        TelemetryChartProjection.segments(
            from: model.telemetryHistory,
            rangeSeconds: historyRangeSeconds,
            expectedRefreshSeconds: refreshSeconds,
            value: value
        )
    }

    private func segmentSeriesKey(_ prefix: String, _ segment: TelemetryChartSegment) -> String {
        "\(prefix).\(segment.id.continuityID).\(segment.id.timestamp.timeIntervalSince1970)"
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(id)
                } else {
                    collapsedSections.insert(id)
                }
                persistCollapsed()
            }
        )
    }

    private func restoreLayout() {
        let preferences = preferencesStore.load()
        let restored = preferences.sectionOrder.compactMap(DashboardSection.init(rawValue:))
        let missing = DashboardSection.allCases.filter { !restored.contains($0) }
        sectionOrder = restored + missing
        collapsedSections = Set(preferences.collapsedSections.map(DashboardSection.canonicalCollapseID(for:)))
        refreshSeconds = [0, 2, 5, 15, 30, 60].contains(preferences.refreshSeconds)
            ? preferences.refreshSeconds
            : 0
        historyRangeSeconds = TelemetryRange(rawValue: preferences.historyRangeSeconds)?.rawValue
            ?? TelemetryRange.day.rawValue
        hiddenChartSeries = preferences.hiddenChartSeries
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        sectionOrder.move(fromOffsets: source, toOffset: destination)
        persistPreferences()
    }

    private func persistCollapsed() {
        persistPreferences()
    }

    private func persistPreferences() {
        preferencesStore.save(DashboardPreferences(
            sectionOrder: sectionOrder.map(\.rawValue),
            collapsedSections: collapsedSections,
            refreshSeconds: refreshSeconds,
            historyRangeSeconds: historyRangeSeconds,
            hiddenChartSeries: hiddenChartSeries
        ))
    }

    private func metric(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func metricVerbatim(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func localizedBatteryState(_ state: String) -> String {
        switch state.lowercased() {
        case "charging": String(localized: "Charging")
        case "discharging": String(localized: "Discharging")
        case "full": String(localized: "Full")
        case "not charging", "not_charging": String(localized: "Not charging")
        default: state
        }
    }

    private func localizedBatteryHealth(_ health: Components.Schemas.BatteryHealth) -> String {
        switch health {
        case .good: String(localized: "Good")
        case .overheat: String(localized: "Overheated")
        case .dead: String(localized: "Dead")
        case .overVoltage: String(localized: "Over voltage")
        case .underVoltage: String(localized: "Under voltage")
        case .unspecifiedFailure: String(localized: "Unspecified failure")
        case .cold: String(localized: "Cold")
        case .watchdogTimerExpire: String(localized: "Watchdog timer expired")
        case .safetyTimerExpire: String(localized: "Safety timer expired")
        case .overCurrent: String(localized: "Over current")
        case .calibrationRequired: String(localized: "Calibration required")
        case .warm: String(localized: "Warm")
        case .cool: String(localized: "Cool")
        case .hot: String(localized: "Hot")
        case .noBattery: String(localized: "No battery")
        case .blownFuse: String(localized: "Blown fuse")
        case .cellImbalance: String(localized: "Cell imbalance")
        }
    }

    private func formatBatteryEstimate(_ seconds: Int, zeroLabel: LocalizedStringResource) -> String {
        seconds == 0 ? String(localized: zeroLabel) : formatDuration(seconds)
    }

    private func formatPercent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private func systemChartAccessibilitySummary(
        _ system: Components.Schemas.SystemStatus,
        showsCPU: Bool,
        showsMemory: Bool,
        showsStorage: Bool
    ) -> String {
        var values: [String] = []
        let latest = visibleTelemetry.reversed()
        if showsCPU, let cpu = system.cpuUsagePercent ?? latest.compactMap(\.cpuUsagePercent).first {
            values.append(String(localized: "CPU \(formatPercent(cpu))"))
        }
        if showsMemory,
           let memory = system.memoryUsedPercent ?? latest.compactMap(\.memoryUsedPercent).first
        {
            values.append(String(localized: "Memory \(formatPercent(memory))"))
        }
        if showsStorage,
           let storage = system.storageUsedPercent ?? latest.compactMap(\.storageUsedPercent).first
        {
            values.append(String(localized: "Storage \(formatPercent(storage))"))
        }
        guard !values.isEmpty else {
            return String(localized: "Historical samples are shown.")
        }
        let summary = values.formatted()
        return String(localized: "Latest system utilization: \(summary).")
    }

    private func localizedNetworkSelection(_ mode: String) -> String {
        switch mode {
        case "automatic": String(localized: "Automatic")
        case "manual": String(localized: "Manual")
        default: String(localized: "Unknown")
        }
    }

    private func aggregationLabel(_ value: Components.Schemas.CarrierAggregationStatus) -> String {
        guard value.active else { return String(localized: "Not aggregated") }
        return value.bands.isEmpty
            ? String(localized: "Active")
            : value.bands.joined(separator: " + ")
    }

    private func capabilityLabel(_ id: Components.Schemas.Capability.IdPayload) -> String {
        switch id {
        case .deviceIdentity: "Device identity"
        case .systemStatus: "System status"
        case .batteryStatus: "Battery status"
        case .thermalStatus: "Thermal status"
        case .signalStatus: "Signal status"
        case .cellularStatus: "Cellular status"
        case .trafficStatus: "Traffic status"
        case .wifiStatus: "Wi-Fi status"
        case .lanClients: "LAN clients"
        case .smsList: "SMS list"
        }
    }

    private func capabilityStatusLabel(_ status: Components.Schemas.CapabilityStatus) -> String {
        switch status {
        case .available: "Available"
        case .degraded: "Degraded"
        case .unsupported: "Unsupported"
        }
    }

    private func capabilityStatusIcon(_ status: Components.Schemas.CapabilityStatus) -> String {
        switch status {
        case .available: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .unsupported: "minus.circle.fill"
        }
    }

    private func capabilityStatusColor(_ status: Components.Schemas.CapabilityStatus) -> Color {
        switch status {
        case .available: .green
        case .degraded: .orange
        case .unsupported: .secondary
        }
    }

    private func batteryIcon(_ value: Int) -> String {
        if value >= 75 {
            return "battery.100"
        }
        if value >= 50 {
            return "battery.75"
        }
        if value >= 25 {
            return "battery.50"
        }
        return "battery.25"
    }

    private func batteryColor(_ value: Int) -> Color {
        if value >= 50 {
            return .green
        }
        if value >= 20 {
            return .yellow
        }
        return .red
    }

    private func formatDuration(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = seconds % 86400 / 3600
        let minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes)m"
    }

    private func formatMetric<T: BinaryInteger>(_ value: T?, unit: String) -> String {
        value.map { "\($0) \(unit)" } ?? "Not reported"
    }

    private func formatMetric<T: BinaryFloatingPoint>(_ value: T?, unit: String) -> String {
        value.map { String(format: "%.1f %@", Double($0), unit) } ?? "Not reported"
    }

    private func formatTraffic(_ value: Components.Schemas.TrafficPeriod) -> String {
        "↓ \(ByteCountFormatter.string(fromByteCount: Int64(value.rxBytes), countStyle: .binary)) · " +
            "↑ \(ByteCountFormatter.string(fromByteCount: Int64(value.txBytes), countStyle: .binary))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
