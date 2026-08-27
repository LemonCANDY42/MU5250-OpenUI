import Charts
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable, Codable {
    case device, capabilities, system, battery, thermal, signal, cellular, traffic, wifi, lanClients, messages

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .device: "Device"
        case .capabilities: "Capabilities"
        case .system: "System status"
        case .battery: "Battery"
        case .thermal: "Thermal"
        case .signal: "Signal"
        case .cellular: "Cellular"
        case .traffic: "Traffic"
        case .wifi: "Wi-Fi"
        case .lanClients: "LAN clients"
        case .messages: "Messages"
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
}

private enum TelemetryRange: Int, CaseIterable, Identifiable {
    case hour = 3_600
    case sixHours = 21_600
    case day = 86_400
    case week = 604_800

    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        }
    }
}

struct DashboardView: View {
    let model: AppModel
    @State private var sectionOrder = DashboardSection.allCases
    @State private var collapsedSections = Set<String>()
    @State private var refreshSeconds = 0
    @State private var historyRangeSeconds = TelemetryRange.day.rawValue
    @State private var showsLayoutEditor = false
    private let preferencesStore = DashboardPreferencesStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = model.dashboard {
                    LazyVStack(spacing: 14) {
                        ForEach(sectionOrder) { section in
                            dashboardSection(section, snapshot: snapshot)
                        }
                        ForEach(snapshot.failures.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                            statusCard(title: key, icon: "exclamationmark.triangle.fill", tint: .orange) {
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
            .navigationTitle("Dashboard")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Refresh frequency", selection: $refreshSeconds) {
                            Text("Manual only").tag(0)
                            Text("Every 15 seconds").tag(15)
                            Text("Every 30 seconds").tag(30)
                            Text("Every minute").tag(60)
                            Text("Every 5 minutes").tag(300)
                        }
                        Picker("Chart range", selection: $historyRangeSeconds) {
                            ForEach(TelemetryRange.allCases) { range in
                                Text(range.title).tag(range.rawValue)
                            }
                        }
                    } label: {
                        Label("Monitoring", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        showsLayoutEditor = true
                    } label: {
                        Label("Arrange dashboard", systemImage: "arrow.up.arrow.down.square")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isWorking {
                        ProgressView()
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
                        ForEach(sectionOrder) { section in
                            Label(section.title, systemImage: section.icon)
                        }
                        .onMove(perform: moveSections)
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
        case .device: deviceCard(snapshot.device)
        case .capabilities: capabilityCard(snapshot.report)
        case .system:
            if let value = snapshot.system { systemCard(value) }
        case .battery:
            if let value = snapshot.battery { batteryCard(value) }
        case .thermal:
            if let value = snapshot.thermal { thermalCard(value) }
        case .signal:
            if let value = snapshot.signal { signalCard(value) }
        case .cellular:
            if let value = snapshot.cellular { cellularCard(value) }
        case .traffic:
            if let value = snapshot.traffic { trafficCard(value) }
        case .wifi:
            if let value = snapshot.wifi { wifiCard(value) }
        case .lanClients:
            if let value = snapshot.lanClients { lanClientsCard(value) }
        case .messages:
            if let value = snapshot.sms { smsCard(value) }
        }
    }

    private func deviceCard(_ device: Components.Schemas.Device?) -> some View {
        statusCard(title: device?.model ?? "U60 Pro", icon: "wifi.router.fill", tint: .blue) {
            if let device {
                Text(device.firmwareVersion ?? device.firmwareTarget)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("\(device.manufacturer) · \(device.adapter)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Identity unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private func capabilityCard(_ report: Components.Schemas.CapabilityReport) -> some View {
        statusCard(title: "Capabilities", icon: "checklist", tint: .indigo) {
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
        statusCard(title: "System status", icon: "cpu", tint: .purple) {
            metric("Uptime", formatDuration(system.uptimeSeconds))
            metric("Load", system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            metric("Kernel", system.kernel)
        }
    }

    private func batteryCard(_ battery: Components.Schemas.BatteryStatus) -> some View {
        statusCard(title: "Battery", icon: batteryIcon(battery.capacityPercent), tint: batteryColor(battery.capacityPercent)) {
            metric("Capacity", "\(battery.capacityPercent)%")
            metric("State", localizedBatteryState(battery.state))
            metric("Voltage", String(format: "%.3f V", Double(battery.voltageMv) / 1000))
            metric("Current", "\(battery.currentMa) mA")
            metric("Temperature", String(format: "%.1f °C", battery.temperatureC))
            let samples = visibleTelemetry.filter { $0.batteryPercent != nil }
            if samples.count >= 2 {
                Divider()
                Text("Battery history").font(.subheadline.weight(.semibold))
                Chart(samples) { sample in
                    if let value = sample.batteryPercent {
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Battery", value)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0 ... 100)
                .frame(height: 150)
            }
        }
    }

    private func thermalCard(_ thermal: Components.Schemas.ThermalStatus) -> some View {
        statusCard(title: "Thermal", icon: "thermometer.medium", tint: .orange) {
            if thermal.sensors.isEmpty {
                Text("No sensors reported").foregroundStyle(.secondary)
            } else {
                ForEach(thermal.sensors, id: \.sensor) { sensor in
                    metricVerbatim(sensor.sensor, String(format: "%.1f °C", sensor.temperatureC))
                }
            }
        }
    }

    private func signalCard(_ signal: Components.Schemas.SignalStatus) -> some View {
        statusCard(title: "Signal", icon: "antenna.radiowaves.left.and.right", tint: .cyan) {
            metric("Network", signal.networkType)
            metric("Provider", signal.provider ?? String(localized: "Not reported"))
            metric("Strength", "\(signal.bars) / 5")
            metric("Roaming", signal.roaming ? String(localized: "Yes") : String(localized: "No"))
            metric("Active band", signal.activeBand ?? String(localized: "Not reported"))
            if let lte = signal.lte {
                metric("LTE band", lte.band ?? String(localized: "Not reported"))
                metric("LTE RSRP", formatMetric(lte.rsrpDbm, unit: "dBm"))
                metric("LTE RSRQ", formatMetric(lte.rsrqDb, unit: "dB"))
                metric("LTE SNR", formatMetric(lte.snrDb, unit: "dB"))
            }
            if let nr5g = signal.nr5g {
                metric("5G band", nr5g.band ?? String(localized: "Not reported"))
                metric("5G channel", nr5g.channel.map(String.init) ?? String(localized: "Not reported"))
                metric("5G PCI", nr5g.pci.map(String.init) ?? String(localized: "Not reported"))
                metric("5G RSRP", formatMetric(nr5g.rsrpDbm, unit: "dBm"))
                metric("5G RSRQ", formatMetric(nr5g.rsrqDb, unit: "dB"))
                metric("5G SNR", formatMetric(nr5g.snrDb, unit: "dB"))
            }
            let samples = visibleTelemetry.filter { $0.lteRSRPdBm != nil || $0.nr5gRSRPdBm != nil }
            if samples.count >= 2 {
                Divider()
                Text("Signal history").font(.subheadline.weight(.semibold))
                Chart(samples) { sample in
                    if let value = sample.lteRSRPdBm {
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("RSRP", value),
                            series: .value("Radio", "LTE")
                        )
                        .foregroundStyle(by: .value("Radio", "LTE"))
                        .interpolationMethod(.monotone)
                    }
                    if let value = sample.nr5gRSRPdBm {
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("RSRP", value),
                            series: .value("Radio", "5G")
                        )
                        .foregroundStyle(by: .value("Radio", "5G"))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(["LTE": Color.blue, "5G": Color.purple])
                .frame(height: 180)
            }
        }
    }

    private func cellularCard(_ cellular: Components.Schemas.CellularStatus) -> some View {
        statusCard(title: "Cellular", icon: "cellularbars", tint: .green) {
            metric("State", cellular.connected ? String(localized: "Connected") : String(localized: "Disconnected"))
            metric("Protocol", cellular._protocol)
            metric("Interface", cellular.interface ?? String(localized: "Not reported"))
            metric("Uptime", formatDuration(cellular.uptimeSeconds))
            metric("IPv4", cellular.ipv4Addresses.joined(separator: ", ").nilIfEmpty ?? String(localized: "None"))
            metric("IPv6", cellular.ipv6Addresses.joined(separator: ", ").nilIfEmpty ?? String(localized: "None"))
        }
    }

    private func trafficCard(_ traffic: Components.Schemas.TrafficStatus) -> some View {
        statusCard(title: "Traffic", icon: "arrow.up.arrow.down", tint: .blue) {
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
        statusCard(title: "Wi-Fi", icon: "wifi", tint: .indigo) {
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
            metric("This iPhone signal", String(localized: "Not exposed by the iOS public API"))
            ForEach(wifi.bands, id: \.band) { band in
                Divider()
                Text(band.band).font(.subheadline.weight(.semibold))
                metric("Network", band.enabled ? band.ssid : String(localized: "Disabled"))
                metric("Radio", "\(band.channel) · \(band.bandwidth)")
                metric("Security", "\(band.encryption)\(band.hidden ? " \(String(localized: "(Hidden)"))" : "")")
                metric("Clients", band.clients.map(String.init) ?? String(localized: "Not reported"))
            }
        }
    }

    private func lanClientsCard(_ value: Components.Schemas.LanClients) -> some View {
        statusCard(title: "LAN clients", icon: "laptopcomputer.and.iphone", tint: .teal) {
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
        statusCard(title: "Messages", icon: "message.fill", tint: .mint) {
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
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        CardView {
            DisclosureGroup(isExpanded: expansionBinding(for: title)) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 8)
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

    private var visibleTelemetry: [TelemetrySample] {
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(historyRangeSeconds))
        return model.telemetryHistory.filter { $0.timestamp >= cutoff }
    }

    private func expansionBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(title) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(title)
                } else {
                    collapsedSections.insert(title)
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
        collapsedSections = preferences.collapsedSections
        refreshSeconds = [0, 15, 30, 60, 300].contains(preferences.refreshSeconds)
            ? preferences.refreshSeconds
            : 0
        historyRangeSeconds = TelemetryRange(rawValue: preferences.historyRangeSeconds)?.rawValue
            ?? TelemetryRange.day.rawValue
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
            historyRangeSeconds: historyRangeSeconds
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
