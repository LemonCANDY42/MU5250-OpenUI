import SwiftUI

struct ControlView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ChargingControlView(model: model)
                    } label: {
                        ControlRow(title: "Charging status", subtitle: chargingSummary, systemImage: "battery.100percent.bolt")
                    }
                    NavigationLink {
                        WifiControlView(model: model)
                    } label: {
                        ControlRow(title: "Wi-Fi", subtitle: wifiSummary, systemImage: "wifi.router")
                    }
                    NavigationLink {
                        TrafficCycleControlView(model: model)
                    } label: {
                        ControlRow(title: "Traffic cycle", subtitle: trafficSummary, systemImage: "calendar.badge.clock")
                    }
                    NavigationLink {
                        SMSControlView(model: model)
                    } label: {
                        ControlRow(
                            title: "Send SMS",
                            subtitle: String(localized: "Send one message through the U60"),
                            systemImage: "message"
                        )
                    }
                    NavigationLink {
                        DevicePowerControlView(model: model)
                    } label: {
                        ControlRow(
                            title: "Device power",
                            subtitle: String(localized: "Restart or power off with password re-entry"),
                            systemImage: "power"
                        )
                    }
                } header: {
                    Text("Daily controls")
                } footer: {
                    Text("Every change is sent through the typed v1 control plane. Wi-Fi changes require reconnection confirmation or are restored automatically.")
                }
            }
            .connectionIssueInset(model.connectionIssue)
            .navigationTitle("Control")
            .refreshable { await model.refresh() }
        }
    }

    private var chargingSummary: String {
        guard let status = model.charging else { return String(localized: "Status unavailable") }
        let state = status.paused ? String(localized: "Charge stopped") : String(localized: "Charging allowed")
        return "\(status.capacityPercent)% · \(state)"
    }

    private var wifiSummary: String {
        guard let wifi = model.dashboard?.wifi else { return String(localized: "Status unavailable") }
        return wifi.enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private var trafficSummary: String {
        guard let traffic = model.dashboard?.traffic else { return String(localized: "Status unavailable") }
        return traffic.resetEnabled
            ? String(localized: "Monthly reset enabled")
            : String(localized: "Monthly reset disabled")
    }
}

private struct DevicePowerControlView: View {
    let model: AppModel
    @State private var pendingAction: DevicePowerAction?
    @State private var showsFirstConfirmation = false
    @State private var showsFinalConfirmation = false
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                Button("Restart U60", role: .destructive) {
                    begin(.reboot)
                }
                Button("Power off U60", role: .destructive) {
                    begin(.powerOff)
                }
            } footer: {
                Text("These actions require the management password again and a second confirmation. A submitted action is never retried automatically.")
            }

            Section("Recovery") {
                Text("Restart preserves the normal boot setup and the app checks only for recovery. After power off, use the physical power button or connect power to start the U60 again.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Device power")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .confirmationDialog(
            firstConfirmationTitle,
            isPresented: $showsFirstConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                Task { @MainActor in
                    await Task.yield()
                    showsFinalConfirmation = true
                }
            }
            Button("Cancel", role: .cancel) {
                reset()
            }
        } message: {
            Text(firstConfirmationMessage)
        }
        .alert(finalConfirmationTitle, isPresented: $showsFinalConfirmation) {
            SecureField("Management password", text: $password)
            Button(finalActionTitle, role: .destructive) {
                submit()
            }
            .disabled(password.isEmpty)
            Button("Cancel", role: .cancel) {
                reset()
            }
        } message: {
            Text("Enter the dedicated OpenU60 management password. It is used only for this request and is not saved.")
        }
    }

    private var firstConfirmationTitle: LocalizedStringKey {
        pendingAction == .powerOff ? "Power off the U60?" : "Restart the U60?"
    }

    private var firstConfirmationMessage: LocalizedStringKey {
        pendingAction == .powerOff
            ? "The U60 will become unreachable until it is physically powered on again."
            : "The U60 and OpenU60 service will be briefly unavailable while the device restarts."
    }

    private var finalConfirmationTitle: LocalizedStringKey {
        pendingAction == .powerOff ? "Final power-off confirmation" : "Final restart confirmation"
    }

    private var finalActionTitle: LocalizedStringKey {
        pendingAction == .powerOff ? "Power off now" : "Restart now"
    }

    private func begin(_ action: DevicePowerAction) {
        pendingAction = action
        password = ""
        showsFirstConfirmation = true
    }

    private func submit() {
        guard let action = pendingAction, !password.isEmpty else {
            reset()
            return
        }
        let submittedPassword = password
        password = ""
        pendingAction = nil
        Task {
            await model.performDevicePowerAction(action, password: submittedPassword)
        }
    }

    private func reset() {
        password = ""
        pendingAction = nil
    }
}

private struct ControlRow: View {
    let title: LocalizedStringKey
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
        .padding(.vertical, 3)
    }
}

private struct ChargingControlView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Status") {
                if let charging = model.charging {
                    LabeledContent("Battery", value: "\(charging.capacityPercent)%")
                    LabeledContent("State", value: charging.paused ? String(localized: "Charge stopped") : String(localized: "Charging allowed"))
                } else {
                    Text("Charging status is unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Charging status")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
    }
}

private struct WifiControlView: View {
    let model: AppModel
    @State private var mainEnabled2g = true
    @State private var mainEnabled5g = true
    @State private var ssid2g = ""
    @State private var passphrase2g = ""
    @State private var hidden2g = false
    @State private var channel2g = "0"
    @State private var bandwidth2g = "EHT20_40"
    @State private var power2g = 30
    @State private var ssid5g = ""
    @State private var passphrase5g = ""
    @State private var hidden5g = false
    @State private var channel5g = "0"
    @State private var bandwidth5g = "EHT160"
    @State private var power5g = 50
    @State private var showsApplyConfirmation = false
    @State private var initialized = false
    @State private var pane = WifiPane.status

    private enum WifiPane: String, CaseIterable, Identifiable {
        case status
        case settings

        var id: Self { self }
        var title: LocalizedStringKey { self == .status ? "Status" : "Modify" }
    }

    private let channels2g = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13"]
    private let channels5g = ["0", "36", "40", "44", "48", "52", "56", "60", "64", "100", "104", "108", "112", "116", "120", "124", "128", "132", "136", "140", "149", "153", "157", "161", "165"]
    private let bandwidths2g = ["EHT20", "EHT40", "EHT20_40"]
    private let bandwidths5g = ["EHT20", "EHT40", "EHT80", "EHT160"]
    private let powers = Array(stride(from: 10, through: 100, by: 10))

    private var stockMultiBandEnabled: Bool {
        model.dashboard?.wifi?.features.bandSteeringEnabled == true
    }

    var body: some View {
        Form {
            Section {
                Picker("Wi-Fi page", selection: $pane) {
                    ForEach(WifiPane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.pendingWifiConfirmation != nil {
                Section {
                    Label("Wi-Fi confirmation required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    LabeledContent(
                        "Automatic verification",
                        value: model.isConfirmingWifi ? String(localized: "Checking…") : String(localized: "Active")
                    )
                    if let message = model.wifiConfirmationMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("You may switch networks more than once. The app keeps checking until it verifies the requested settings or the U60 restores the previous settings after two minutes.")
                        .font(.footnote)
                    Button("Check again now") {
                        Task { await model.confirmWifiTransaction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isConfirmingWifi)
                }
            }

            if pane == .status, let wifi = model.dashboard?.wifi {
                Section("Current status") {
                    LabeledContent("Wi-Fi", value: wifi.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    LabeledContent(
                        "Wi-Fi 7",
                        value: wifi.features.wifi7Active
                            ? String(localized: "Active")
                            : String(localized: "Inactive")
                    )
                    LabeledContent(
                        "Wi-Fi generation switch",
                        value: wifi.features.versionSwitchReportedSupported && !wifi.features.versionSwitchStateAvailable
                            ? String(localized: "Reported by firmware; no safe control source")
                            : String(localized: "Unavailable")
                    )
                    LabeledContent(
                        "Multi-Link Operation (MLO)",
                        value: wifi.features.mloSupported
                            ? (wifi.features.mloEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                            : String(localized: "Not supported on this B04")
                    )
                    LabeledContent(
                        "Multi-band integration",
                        value: wifi.features.bandSteeringSupported
                            ? (wifi.features.bandSteeringEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                            : String(localized: "Unavailable")
                    )
                    if let link = wifi.currentClientLink {
                        LabeledContent("This iPhone signal", value: "\(link.signalDbm) dBm · \(link.band)")
                        WifiSignalLevelRow(signalDbm: link.signalDbm)
                        Text("Measured by the U60 for this authenticated client.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("This iPhone signal", value: String(localized: "Not currently observed by the U60"))
                    }
                }
                ForEach(wifi.bands, id: \.band) { band in
                    Section(band.band) {
                        LabeledContent(
                            "Primary AP switch",
                            value: (band.accessPointEnabled ?? band.enabled)
                                ? String(localized: "Enabled")
                                : String(localized: "Disabled")
                        )
                        LabeledContent(
                            "Currently broadcasting",
                            value: band.enabled ? String(localized: "Yes") : String(localized: "No")
                        )
                        LabeledContent("SSID", value: band.ssid)
                        LabeledContent("Configured channel", value: channelLabel(band.channel))
                        LabeledContent(
                            "Current channel",
                            value: band.activeChannel.map { channelLabel(String($0)) }
                                ?? String(localized: "Unavailable")
                        )
                        LabeledContent("Bandwidth", value: bandwidthLabel(band.bandwidth))
                        LabeledContent(
                            "TX power",
                            value: band.transmitPowerPercent.map(wifiTransmitPowerLabel)
                                ?? String(localized: "Unavailable")
                        )
                        LabeledContent("Security", value: band.encryption)
                        LabeledContent("Clients", value: band.clients.map(String.init) ?? String(localized: "Unavailable"))
                    }
                }
            }

            if pane == .settings {
                if stockMultiBandEnabled {
                    Section {
                        LabeledContent("Stock multi-band mode", value: String(localized: "Enabled on the U60"))
                    } footer: {
                        Text("This App treats the U60's stock multi-band mode as read-only. 5 GHz network identity follows 2.4 GHz, and individual band switches become available after you turn multi-band mode off on the U60 itself.")
                            .foregroundStyle(.secondary)
                    }
                }

                WifiRadioSettingsSection(
                    title: "2.4 GHz", enabled: $mainEnabled2g,
                    ssid: $ssid2g, passphrase: $passphrase2g, hidden: $hidden2g,
                    channel: $channel2g, bandwidth: $bandwidth2g, power: $power2g,
                    channels: channels2g, bandwidths: bandwidths2g, powers: powers,
                    enabledControlDisabled: stockMultiBandEnabled
                )
                WifiRadioSettingsSection(
                    title: "5 GHz", enabled: $mainEnabled5g,
                    ssid: $ssid5g, passphrase: $passphrase5g, hidden: $hidden5g,
                    channel: $channel5g, bandwidth: $bandwidth5g, power: $power5g,
                    channels: channels5g, bandwidths: bandwidths5g, powers: powers,
                    showsFixed5gNote: true,
                    enabledControlDisabled: stockMultiBandEnabled,
                    identityFollowsPrimary: stockMultiBandEnabled
                )

                if let guest = model.dashboard?.wifi?.guest {
                    Section {
                        NavigationLink("Guest network") {
                            GuestWifiControlView(model: model, guest: guest)
                        }
                    } footer: {
                        Text("Guest changes use the same two-minute rollback protection.")
                    }
                }

                Section {
                    Button("Apply with two-minute rollback") { showsApplyConfirmation = true }
                        .frame(maxWidth: .infinity)
                        .disabled(!mainEnabled2g && !mainEnabled5g)
                } footer: {
                    if !mainEnabled2g && !mainEnabled5g {
                        Text("At least one primary band must remain enabled here. Use the U60's own Wi-Fi control to turn all Wi-Fi off.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("The U60 saves the old values and arms an independent rollback process before changing Wi-Fi. Only verified device readback can cancel rollback.")
                    }
                }
            }
        }
        .navigationTitle("Wi-Fi")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .task { initializeIfNeeded() }
        .onChange(of: model.wifiSettingsRevision) { _, _ in
            initializeIfNeeded(force: true)
        }
        .onChange(of: ssid2g) { _, value in
            if stockMultiBandEnabled { ssid5g = value }
        }
        .onChange(of: hidden2g) { _, value in
            if stockMultiBandEnabled { hidden5g = value }
        }
        .alert("Apply Wi-Fi changes?", isPresented: $showsApplyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Apply with rollback", action: apply)
        } message: {
            Text("Wi-Fi will restart briefly. Reconnect within two minutes; the app will keep checking even if you switch networks more than once.")
        }
    }

    private func initializeIfNeeded(force: Bool = false) {
        guard (!initialized || force), let wifi = model.dashboard?.wifi else { return }
        initialized = true
        if let band = wifi.bands.first(where: { $0.band.contains("2.4") }) {
            mainEnabled2g = band.accessPointEnabled ?? band.enabled
            ssid2g = band.ssid
            hidden2g = band.hidden
            channel2g = normalizedChannel(band.channel, allowed: channels2g)
            bandwidth2g = bandwidths2g.contains(band.bandwidth) ? band.bandwidth : "EHT20_40"
            power2g = normalizedPower(band.transmitPowerPercent)
        }
        if let band = wifi.bands.first(where: { $0.band.contains("5") }) {
            mainEnabled5g = band.accessPointEnabled ?? band.enabled
            ssid5g = band.ssid
            hidden5g = band.hidden
            channel5g = normalizedChannel(band.channel, allowed: channels5g)
            bandwidth5g = bandwidths5g.contains(band.bandwidth) ? band.bandwidth : "EHT160"
            power5g = normalizedPower(band.transmitPowerPercent)
        }
    }

    private func normalizedChannel(_ value: String, allowed: [String]) -> String {
        let normalized = value == "auto" ? "0" : value
        return allowed.contains(normalized) ? normalized : "0"
    }

    private func normalizedPower(_ value: Int?) -> Int {
        guard let value else { return 50 }
        return min(100, max(10, Int(round(Double(value) / 10.0) * 10)))
    }

    private func apply() {
        if stockMultiBandEnabled {
            ssid5g = ssid2g
            hidden5g = hidden2g
            passphrase5g = ""
        }
        let edits = WifiTransactionEdits(
            ssid2g: ssid2g,
            passphrase2g: optional(passphrase2g),
            hidden2g: hidden2g,
            mainEnabled2g: mainEnabled2g,
            channel2g: channel2g,
            bandwidth2g: bandwidth2g,
            transmitPower2g: power2g,
            ssid5g: ssid5g,
            passphrase5g: optional(passphrase5g),
            hidden5g: hidden5g,
            mainEnabled5g: mainEnabled5g,
            channel5g: channel5g,
            bandwidth5g: bandwidth5g,
            transmitPower5g: power5g
        )
        passphrase2g = ""
        passphrase5g = ""
        Task { await model.beginWifiTransaction(edits) }
    }

}

private struct WifiRadioSettingsSection: View {
    let title: LocalizedStringKey
    @Binding var enabled: Bool
    @Binding var ssid: String
    @Binding var passphrase: String
    @Binding var hidden: Bool
    @Binding var channel: String
    @Binding var bandwidth: String
    @Binding var power: Int
    let channels: [String]
    let bandwidths: [String]
    let powers: [Int]
    var showsFixed5gNote = false
    var enabledControlDisabled = false
    var identityFollowsPrimary = false

    var body: some View {
        Section {
            Toggle("Primary AP", isOn: $enabled)
                .disabled(enabledControlDisabled)
            TextField("SSID", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(identityFollowsPrimary)
            SecureField("New password (leave blank to keep current)", text: $passphrase)
                .disabled(identityFollowsPrimary)
            Toggle("Hidden SSID", isOn: $hidden)
                .disabled(identityFollowsPrimary)
            if identityFollowsPrimary {
                Text("Network identity follows 2.4 GHz while multi-band integration is enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker("Channel", selection: $channel) {
                ForEach(channels, id: \.self) { Text(channelLabel($0)).tag($0) }
            }
            Picker("Bandwidth", selection: $bandwidth) {
                ForEach(bandwidths, id: \.self) { Text(bandwidthLabel($0)).tag($0) }
            }
            Picker("TX power", selection: $power) {
                ForEach(powers, id: \.self) { Text(wifiTransmitPowerLabel($0)).tag($0) }
            }
        } header: {
            Text(title)
        } footer: {
            if power <= 20 {
                Text("Low transmit power can reduce range or prevent clients from reconnecting.")
                    .foregroundStyle(.orange)
            }
            if showsFixed5gNote {
                Text("This B04 firmware exposes fixed 20, 40, 80, and 160 MHz widths for 5 GHz; it does not advertise a combined automatic width.")
            }
        }
    }
}

private struct GuestWifiControlView: View {
    let model: AppModel
    let guest: Components.Schemas.WifiGuestStatus
    @State private var enabled2g: Bool
    @State private var enabled5g: Bool
    @State private var ssid: String
    @State private var passphrase = ""
    @State private var hidden: Bool
    @State private var isolation: Bool
    @State private var activeTime: Int
    @State private var confirmApply = false

    private let durations = [0, 30, 60, 120, 240, 480, 720, 1440]

    init(model: AppModel, guest: Components.Schemas.WifiGuestStatus) {
        self.model = model
        self.guest = guest
        _enabled2g = State(initialValue: guest.enabled2g)
        _enabled5g = State(initialValue: guest.enabled5g)
        _ssid = State(initialValue: guest.ssid)
        _hidden = State(initialValue: guest.hidden)
        _isolation = State(initialValue: guest.isolation)
        _activeTime = State(initialValue: guest.activeTimeMinutes)
    }

    var body: some View {
        Form {
            Section("Radio bands") {
                Toggle("2.4 GHz", isOn: $enabled2g)
                Toggle("5 GHz", isOn: $enabled5g)
            }
            Section("Network") {
                TextField("SSID", text: $ssid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("New password (leave blank to keep current)", text: $passphrase)
                Toggle("Hidden SSID", isOn: $hidden)
                Toggle("Client isolation", isOn: $isolation)
            }
            Section("Timer") {
                Picker("Auto-shutoff", selection: $activeTime) {
                    ForEach(durations, id: \.self) { duration in
                        Text(durationLabel(duration)).tag(duration)
                    }
                }
            }
            Section {
                Button("Apply with two-minute rollback") { confirmApply = true }
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Guest network")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .alert("Apply guest network changes?", isPresented: $confirmApply) {
            Button("Apply with rollback") {
                let edits = WifiTransactionEdits(
                    guestEnabled2g: enabled2g,
                    guestEnabled5g: enabled5g,
                    guestSSID: ssid,
                    guestPassphrase: optional(passphrase),
                    guestHidden: hidden,
                    guestIsolation: isolation,
                    guestActiveTimeMinutes: activeTime
                )
                passphrase = ""
                Task { await model.beginWifiTransaction(edits) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wi-Fi will restart briefly. Reconnect within two minutes so the app can verify the requested settings.")
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "No limit")
        case 30: String(localized: "30 minutes")
        case 60: String(localized: "1 hour")
        case 120: String(localized: "2 hours")
        case 240: String(localized: "4 hours")
        case 480: String(localized: "8 hours")
        case 720: String(localized: "12 hours")
        case 1440: String(localized: "24 hours")
        default: "\(minutes) min"
        }
    }
}

private struct TrafficCycleControlView: View {
    let model: AppModel
    @State private var resetDay = 1
    @State private var enabled = true
    @State private var confirmApply = false

    var body: some View {
        Form {
            Section("Monthly cycle") {
                Stepper("Reset day: \(resetDay)", value: $resetDay, in: 1 ... 31)
                Toggle("Enable monthly reset", isOn: $enabled)
            }
            Section {
                Button("Apply and verify") { confirmApply = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("The previous cycle settings are restored if device readback does not match.")
            }
        }
        .navigationTitle("Traffic cycle")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .task {
            if let traffic = model.dashboard?.traffic {
                resetDay = traffic.resetDay
                enabled = traffic.resetEnabled
            }
        }
        .alert("Apply traffic cycle?", isPresented: $confirmApply) {
            Button("Apply and verify") { Task { await model.setTrafficCycle(day: resetDay, enabled: enabled) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The U60 will read the setting back and restore the previous value if verification fails.")
        }
    }
}

private struct SMSControlView: View {
    let model: AppModel
    @State private var recipient = ""
    @State private var message = ""
    @State private var confirmSend = false

    var body: some View {
        Form {
            Section("Message") {
                TextField("Recipient", text: $recipient)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("Message", text: $message, axis: .vertical)
                    .lineLimit(3 ... 6)
                LabeledContent("Characters", value: "\(message.count)/160")
            }
            Section {
                Button("Send message") { confirmSend = true }
                    .disabled(recipient.isEmpty || message.isEmpty || message.count > 160)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Send SMS")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        .alert("Send this SMS?", isPresented: $confirmSend) {
            Button("Send") {
                let submittedRecipient = recipient
                let submittedMessage = message
                message = ""
                Task { await model.sendSMS(recipient: submittedRecipient, message: submittedMessage) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The message will be sent through the U60 modem.")
        }
    }
}

private func optional(_ value: String) -> String? {
    value.isEmpty ? nil : value
}

private func channelLabel(_ value: String) -> String {
    value == "0" || value == "auto" ? String(localized: "Auto") : String(localized: "Channel \(value)")
}

private func bandwidthLabel(_ value: String) -> String {
    switch value {
    case "EHT20": "20 MHz"
    case "EHT40": "40 MHz"
    case "EHT20_40": "20/40 MHz"
    case "EHT80": "80 MHz"
    case "EHT160": "160 MHz"
    default: value
    }
}
