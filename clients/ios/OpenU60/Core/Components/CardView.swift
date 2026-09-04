import SwiftUI

struct CardView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 12))
    }
}
