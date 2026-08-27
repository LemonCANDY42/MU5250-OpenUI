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
            model.notice?.title ?? "OpenU60",
            isPresented: Binding(
                get: { model.errorMessage != nil || model.notice != nil },
                set: {
                    if !$0 {
                        model.dismissPresentedMessage()
                    }
                }
            )
        ) {
            Button("OK") { model.dismissPresentedMessage() }
        } message: {
            Text(model.errorMessage ?? model.notice?.message ?? "")
        }
    }
}
