import SwiftUI

struct ControlView: View {
    let model: AppModel

    @State private var recipient = ""
    @State private var message = ""
    @State private var chargeLimit = 80
    @State private var trafficDay = 1
    @State private var trafficEnabled = true
    @State private var ssid2g = ""
    @State private var passphrase2g = ""
    @State private var ssid5g = ""
    @State private var passphrase5g = ""
    @State private var confirmSMS = false
    @State private var confirmWifi = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Charging") {
                    if let charging = model.charging {
                        LabeledContent("Battery", value: "\(charging.capacityPercent)%")
                        LabeledContent("State", value: charging.paused ? "Paused" : "Charging allowed")
                        LabeledContent(
                            "Automatic limit",
                            value: charging.automaticLimitPercent.map { "\($0)%" } ?? "Disabled"
                        )
                    }
                    Stepper("Limit: \(chargeLimit)%", value: $chargeLimit, in: 50 ... 95)
                    Button("Apply automatic limit") {
                        Task { await model.setCharging(operation: .setLimit, limit: chargeLimit) }
                    }
                    HStack {
                        Button("Pause") { Task { await model.setCharging(operation: .pause) } }
                        Spacer()
                        Button("Resume") { Task { await model.setCharging(operation: .resume) } }
                    }
                    Button("Disable automatic limit", role: .destructive) {
                        Task { await model.setCharging(operation: .disableLimit) }
                    }
                }

                Section("Send SMS") {
                    TextField("Recipient", text: $recipient)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3 ... 6)
                    Button("Send message") { confirmSMS = true }
                        .disabled(recipient.isEmpty || message.isEmpty || message.count > 160)
                }

                Section("Traffic cycle") {
                    Stepper("Reset day: \(trafficDay)", value: $trafficDay, in: 1 ... 31)
                    Toggle("Enable monthly reset", isOn: $trafficEnabled)
                    Button("Apply and verify") {
                        Task { await model.setTrafficCycle(day: trafficDay, enabled: trafficEnabled) }
                    }
                }

                Section {
                    TextField("2.4 GHz SSID (optional)", text: $ssid2g)
                        .textInputAutocapitalization(.never)
                    SecureField("2.4 GHz passphrase (optional)", text: $passphrase2g)
                    TextField("5 GHz SSID (optional)", text: $ssid5g)
                        .textInputAutocapitalization(.never)
                    SecureField("5 GHz passphrase (optional)", text: $passphrase5g)
                    Button("Apply with two-minute rollback") { confirmWifi = true }
                        .disabled([ssid2g, passphrase2g, ssid5g, passphrase5g].allSatisfy(\.isEmpty))
                    if let pending = model.pendingWifiTransaction {
                        Button("Confirm current Wi-Fi") {
                            Task { await model.confirmWifiTransaction() }
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Reconnect if needed and confirm within \(pending.confirmWithinSeconds.rawValue) seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Wi-Fi transaction")
                } footer: {
                    Text("Unconfirmed settings are restored by an independent device process. A reboot also restores the pending transaction before the agent starts.")
                }
            }
            .navigationTitle("Control")
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking { ProgressView().controlSize(.large) }
            }
            .confirmationDialog("Send this SMS?", isPresented: $confirmSMS) {
                Button("Send") {
                    let submittedRecipient = recipient
                    let submittedMessage = message
                    message = ""
                    Task { await model.sendSMS(recipient: submittedRecipient, message: submittedMessage) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Apply Wi-Fi changes?", isPresented: $confirmWifi) {
                Button("Apply with rollback") {
                    let values = (
                        optional(ssid2g), optional(passphrase2g),
                        optional(ssid5g), optional(passphrase5g)
                    )
                    passphrase2g = ""
                    passphrase5g = ""
                    Task {
                        await model.beginWifiTransaction(
                            ssid2g: values.0,
                            passphrase2g: values.1,
                            ssid5g: values.2,
                            passphrase5g: values.3
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("U60 operation failed", isPresented: errorPresented) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Unknown error")
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func optional(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
