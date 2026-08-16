import SwiftUI

struct LoginView: View {
    let model: AppModel
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "wifi.router.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text("U60 Pro")
                                .font(.title2.bold())
                            Text(model.profile?.baseURL.absoluteString ?? "Local HTTPS")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Local device key") {
                    Button("Sign in with this iPhone") {
                        Task { await model.signInWithDeviceKey() }
                    }
                    .disabled(model.isWorking || model.credential == nil)
                    if model.credential?.secureEnclaveBacked == false {
                        Label("Simulator test key — not a passkey", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    SecureField("Dedicated management password", text: $password)
                        .textContentType(.password)
                    Button("Sign in with password") {
                        let value = password
                        password = ""
                        Task { await model.signInWithPassword(value) }
                    }
                    .disabled(model.isWorking || password.isEmpty)
                } header: {
                    Text("Recovery password")
                } footer: {
                    Text("This is the separately generated U60 management password, never the stock router password. It is cleared before transmission and is not stored by the app.")
                }
                DiscardLocalCredentialSection(model: model)
            }
            .navigationTitle("OpenU60")
            .overlay {
                if model.isWorking {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }
}
