import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var confirmsForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Endpoint", value: model.profile?.baseURL.absoluteString ?? "—")
                    LabeledContent("Certificate pin", value: abbreviatedPin)
                    LabeledContent("Credential", value: model.credential?.label ?? "—")
                    LabeledContent(
                        "Key storage",
                        value: model.credential?.secureEnclaveBacked == true ? "Secure Enclave" : "Simulator test key"
                    )
                }
                Section {
                    Button("Sign out") { Task { await model.signOut() } }
                    Button("Discard local credential", role: .destructive) { confirmsForget = true }
                } footer: {
                    Text("Forgetting this app does not revoke the public key on the U60. Revoke it separately through USB maintenance.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Discard this local key and certificate pin?",
                isPresented: $confirmsForget,
                titleVisibility: .visible
            ) {
                Button("Discard local credential", role: .destructive) {
                    Task { await model.discardLocalPairing() }
                }
            }
        }
    }

    private var abbreviatedPin: String {
        guard let pin = model.profile?.spkiSHA256 else { return "—" }
        return String(pin.prefix(18)) + "…"
    }
}
