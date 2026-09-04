import SwiftUI

struct WifiSignalLevelRow: View {
    let signalDbm: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Signal level")
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let level = WifiSignalLevel(signalDbm: signalDbm) {
                    Text(level.label)
                    Text(verbatim: level.rangeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable")
                }
            }
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
