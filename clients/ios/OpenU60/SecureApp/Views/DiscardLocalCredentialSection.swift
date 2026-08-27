import SwiftUI

struct DiscardLocalCredentialSection: View {
    let model: AppModel
    @State private var confirmsDiscard = false

    var body: some View {
        Section {
            Button("Discard local credential", role: .destructive) {
                confirmsDiscard = true
            }
        } footer: {
            Text("Use this if the local key or pairing data is damaged. This does not revoke the public key on the U60; revoke it separately through USB maintenance.")
        }
        .alert(
            "Discard this local key and certificate pin?",
            isPresented: $confirmsDiscard
        ) {
            Button("Discard local credential", role: .destructive) {
                Task { await model.discardLocalPairing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the credential stored on this iPhone; it does not revoke the public key on the U60.")
        }
    }
}
