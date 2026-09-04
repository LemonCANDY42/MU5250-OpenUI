import SwiftUI

struct CellularSignalLevelRow: View {
    let title: LocalizedStringKey
    let technology: CellularTechnology
    let rsrpDbm: Int?

    var body: some View {
        if let level = CellularSignalLevel(technology: technology, rsrpDbm: rsrpDbm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(level.label)
                    Text(verbatim: level.rangeDescription(for: technology))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
