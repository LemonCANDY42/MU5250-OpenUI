import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .booting:
                ProgressView("Opening local credential…")
            case .needsPairing:
                PairingView(model: model)
            case .signedOut:
                LoginView(model: model)
            case .authenticated:
                MainView(model: model)
            }
        }
        .alert(
            "OpenU60",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
