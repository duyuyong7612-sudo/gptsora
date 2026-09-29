// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-0babe52fafd17b427955ace619113719a4f148eed56460e290c7ed5afb65766b"
// Source-SHA256: "7e13cca67c2d52a7bb58f0d868c291dce48e9fad6249259c8d335efb33b33b24"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
