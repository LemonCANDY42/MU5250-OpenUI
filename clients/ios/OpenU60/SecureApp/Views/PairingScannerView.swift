import SwiftUI
import VisionKit

struct PairingScannerView: UIViewControllerRepresentable {
    let onValue: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onValue: onValue)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIHostingController(rootView: ContentUnavailableView(
                "Scanner unavailable",
                systemImage: "qrcode",
                description: Text("Paste the pairing JSON instead.")
            ))
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onValue: @MainActor (String) -> Void
        private var delivered = false

        init(onValue: @escaping @MainActor (String) -> Void) {
            self.onValue = onValue
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems _: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let value = barcode.payloadStringValue
                else { continue }
                delivered = true
                dataScanner.stopScanning()
                onValue(value)
                return
            }
        }
    }
}
