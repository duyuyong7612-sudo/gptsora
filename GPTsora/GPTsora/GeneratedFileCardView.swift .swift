// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d4b9ba6c8ffba8224dd17a58e318682536e837381bd03582962025caa59c8300"
// Source-SHA256: "8324aea159f16e08daf690116ee63915a8f46d4dda6b0652c7a2197e03a92aec"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import UIKit

struct GeneratedFileCardView: View {
    let file: GeneratedCodeFile

    @State private var copied = false
    @State private var exportURL: URL?
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 42, height: 42)

                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.baseName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Text("Code")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Text("·")
                            .foregroundColor(.secondary)

                        Text(file.displayType)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        if !file.isClosed {
                            Text("·")
                                .foregroundColor(.secondary)

                            Text("生成中")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    smallButton(title: copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = file.content
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    }

                    smallButton(title: "Share") {
                        do {
                            let url = try CodeExportService.writeSingleFile(file)
                            exportURL = url
                            shareItems = [url]
                            showShareSheet = true
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }

                    primaryButton(title: "Download") {
                        do {
                            let url = try CodeExportService.writeSingleFile(file)
                            exportURL = url
                            shareItems = [url]
                            showShareSheet = true
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(!file.isClosed)
                    .opacity(file.isClosed ? 1 : 0.6)
                }
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(activityItems: shareItems)
        }
        .alert("导出失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue { errorMessage = nil }
            }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var iconName: String {
        switch file.fileExtension {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "html", "css", "js", "ts", "json", "xml", "yaml", "yml":
            return "doc.text"
        case "md":
            return "text.alignleft"
        case "zip":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private func smallButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
