import SwiftUI

struct MainView: View {
    let model: AppModel

    var body: some View {
        TabView {
            DashboardView(model: model)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
            ControlView(model: model)
                .tabItem { Label("Control", systemImage: "switch.2") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
