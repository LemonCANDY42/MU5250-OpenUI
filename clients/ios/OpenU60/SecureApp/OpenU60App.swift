import SwiftUI

@main
struct OpenU60SecureApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.boot() }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        model.resumeWifiConfirmation()
                    }
                }
        }
    }
}
