import SwiftUI

struct DashboardView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = model.dashboard {
                    LazyVStack(spacing: 14) {
                        deviceCard(snapshot.device)
                        capabilityCard(snapshot.report)
                        if let system = snapshot.system {
                            systemCard(system)
                        }
                        if let battery = snapshot.battery {
                            batteryCard(battery)
                        }
                        if let thermal = snapshot.thermal {
                            thermalCard(thermal)
                        }
                        if let signal = snapshot.signal {
                            signalCard(signal)
                        }
                        if let cellular = snapshot.cellular {
                            cellularCard(cellular)
                        }
                        if let traffic = snapshot.traffic {
                            trafficCard(traffic)
                        }
                        if let wifi = snapshot.wifi {
                            wifiCard(wifi)
                        }
                        if let clients = snapshot.lanClients {
                            lanClientsCard(clients)
                        }
                        if let sms = snapshot.sms {
                            smsCard(sms)
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
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isWorking {
                        ProgressView()
                    }
                }
            }
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
        statusCard(title: "System", icon: "cpu", tint: .purple) {
            metric("Uptime", formatDuration(system.uptimeSeconds))
            metric("Load", system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            metric("Kernel", system.kernel)
        }
    }

    private func batteryCard(_ battery: Components.Schemas.BatteryStatus) -> some View {
        statusCard(title: "Battery", icon: batteryIcon(battery.capacityPercent), tint: batteryColor(battery.capacityPercent)) {
            metric("Capacity", "\(battery.capacityPercent)%")
            metric("State", battery.state)
            metric("Voltage", String(format: "%.3f V", Double(battery.voltageMv) / 1000))
            metric("Current", "\(battery.currentMa) mA")
            metric("Temperature", String(format: "%.1f °C", battery.temperatureC))
        }
    }

    private func thermalCard(_ thermal: Components.Schemas.ThermalStatus) -> some View {
        statusCard(title: "Thermal", icon: "thermometer.medium", tint: .orange) {
            if thermal.sensors.isEmpty {
                Text("No sensors reported").foregroundStyle(.secondary)
            } else {
                ForEach(thermal.sensors, id: \.sensor) { sensor in
                    metric(sensor.sensor, String(format: "%.1f °C", sensor.temperatureC))
                }
            }
        }
    }

    private func signalCard(_ signal: Components.Schemas.SignalStatus) -> some View {
        statusCard(title: "Signal", icon: "antenna.radiowaves.left.and.right", tint: .cyan) {
            metric("Network", signal.networkType)
            metric("Provider", signal.provider ?? "Not reported")
            metric("Strength", "\(signal.bars) / 5")
            metric("Roaming", signal.roaming ? "Yes" : "No")
            metric("Active band", signal.activeBand ?? "Not reported")
            if let lte = signal.lte {
                metric("LTE band", lte.band ?? "Not reported")
                metric("LTE RSRP", formatMetric(lte.rsrpDbm, unit: "dBm"))
                metric("LTE RSRQ", formatMetric(lte.rsrqDb, unit: "dB"))
                metric("LTE SNR", formatMetric(lte.snrDb, unit: "dB"))
            }
            if let nr5g = signal.nr5g {
                metric("5G band", nr5g.band ?? "Not reported")
                metric("5G channel", nr5g.channel.map(String.init) ?? "Not reported")
                metric("5G PCI", nr5g.pci.map(String.init) ?? "Not reported")
                metric("5G RSRP", formatMetric(nr5g.rsrpDbm, unit: "dBm"))
                metric("5G RSRQ", formatMetric(nr5g.rsrqDb, unit: "dB"))
                metric("5G SNR", formatMetric(nr5g.snrDb, unit: "dB"))
            }
        }
    }

    private func cellularCard(_ cellular: Components.Schemas.CellularStatus) -> some View {
        statusCard(title: "Cellular", icon: "cellularbars", tint: .green) {
            metric("State", cellular.connected ? "Connected" : "Disconnected")
            metric("Protocol", cellular._protocol)
            metric("Interface", cellular.interface ?? "Not reported")
            metric("Uptime", formatDuration(cellular.uptimeSeconds))
            metric("IPv4", cellular.ipv4Addresses.joined(separator: ", ").nilIfEmpty ?? "None")
            metric("IPv6", cellular.ipv6Addresses.joined(separator: ", ").nilIfEmpty ?? "None")
        }
    }

    private func trafficCard(_ traffic: Components.Schemas.TrafficStatus) -> some View {
        statusCard(title: "Traffic", icon: "arrow.up.arrow.down", tint: .blue) {
            metric("Today", formatTraffic(traffic.day))
            metric("Billing cycle", formatTraffic(traffic.cycle))
            metric("Since power-on", formatTraffic(traffic.sincePowerOn))
            metric("All time", formatTraffic(traffic.total))
            metric("Cycle reset", traffic.resetEnabled ? "Day \(traffic.resetDay)" : "Disabled")
        }
    }

    private func wifiCard(_ wifi: Components.Schemas.WifiStatus) -> some View {
        statusCard(title: "Wi-Fi", icon: "wifi", tint: .indigo) {
            metric("Overall", wifi.enabled ? "Enabled" : "Disabled")
            ForEach(wifi.bands, id: \.band) { band in
                Divider()
                Text(band.band).font(.subheadline.weight(.semibold))
                metric("Network", band.enabled ? band.ssid : "Disabled")
                metric("Radio", "\(band.channel) · \(band.bandwidth)")
                metric("Security", "\(band.encryption)\(band.hidden ? " · hidden" : "")")
                metric("Clients", band.clients.map(String.init) ?? "Not reported")
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
        @ViewBuilder content: () -> some View
    ) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
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
