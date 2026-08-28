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

extension View {
    func connectionIssueInset(_ issue: ConnectionIssue?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let issue {
                ConnectionIssueBanner(issue: issue)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: issue)
    }
}

private struct ConnectionIssueBanner: View {
    let issue: ConnectionIssue

    private var tint: Color {
        switch issue {
        case .weak: .orange
        case .disconnected: .red
        }
    }

    var body: some View {
        Label {
            Text(issue.message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: issue.systemImage)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
