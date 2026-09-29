// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-b9b3db551def602ac27fe07171164bbae1411eba39c5ccfa5c1b377bbe874413"
// Source-SHA256: "550a9ef07d14a449d18b9d9bdd61813fa0520cabf53cdc1787cd7655a0183571"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct CodeBundleCardView: View {
    let title: String
    let files: [GeneratedCodeFile]

    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    private var displayTitle: String {
        if files.count <= 1 {
            return title.isEmpty ? "代码文件" : title
        }
        return title.isEmpty ? "代码下载包" : title
    }

    private var subtitleText: String {
        if files.count <= 1 {
            return "1 file"
        }
        return "\(files.count) files"
    }

    private var hasIncompleteFiles: Bool {
        files.contains(where: { !$0.isClosed })
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: files.count <= 1 ? "doc" : "archivebox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    if hasIncompleteFiles {
                        Text("·")
                            .foregroundColor(.secondary)

                        Text("生成中")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            Button {
                exportBundle()
            } label: {
                Text("Download")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(files.isEmpty || hasIncompleteFiles)
            .opacity((files.isEmpty || hasIncompleteFiles) ? 0.6 : 1)
        }
        .padding(14)
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
        .alert(
            "导出失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportBundle() {
        do {
            if files.count == 1, let first = files.first {
                let url = try CodeExportService.writeSingleFile(first)
                shareItems = [url]
            } else {
                let url = try CodeExportService.exportPackageDirectory(files, packageName: displayTitle)
                shareItems = [url]
            }
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
