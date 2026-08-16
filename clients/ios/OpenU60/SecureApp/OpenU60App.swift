import SwiftUI

@main
struct OpenU60SecureApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.boot() }
        }
    }
}
