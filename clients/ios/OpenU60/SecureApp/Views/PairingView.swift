import SwiftUI

struct PairingView: View {
    let model: AppModel
    @State private var payloadText = ""
    @State private var label = "Kenny’s iPhone"
    @State private var showsScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Connect to the U60 over USB maintenance first.", systemImage: "cable.connector")
                    Text("Open a five-minute pairing window and scan its QR code. The code binds this app to the local HTTPS address and certificate fingerprint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("This device") {
                    TextField("Key label", text: $label)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section("Pairing code") {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    TextEditor(text: $payloadText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Pairing payload")
                }
                Section {
                    Button("Pair securely") {
                        let payload = payloadText
                        payloadText = ""
                        Task { await model.pair(payloadText: payload, label: label) }
                    }
                    .disabled(model.isWorking || payloadText.isEmpty || label.isEmpty)
                } footer: {
                    Text("The private signing key never leaves this iPhone. The one-time nonce is cleared from the form before the request starts.")
                }
                DiscardLocalCredentialSection(model: model)
            }
            .navigationTitle("Pair U60")
            .overlay {
                if model.isWorking {
                    ProgressView().controlSize(.large)
                }
            }
            .sheet(isPresented: $showsScanner) {
                PairingScannerView { value in
                    payloadText = value
                    showsScanner = false
                }
            }
        }
    }
}
