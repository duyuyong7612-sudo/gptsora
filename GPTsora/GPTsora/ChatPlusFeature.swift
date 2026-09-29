// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-057278bfd6af9ebcc7a984da28e0fe5af3993190a724cda594f2a68b7dfe3393"
// Source-SHA256: "bd8890c86f0c280a0da82bc2336acb4355357aba552e4968f88b14c8abdcad5d"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import Combine
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// =======================================================
// ChatPlusFeature.swift
// ✅ 统一「(+)」入口：相册 / 拍照 / 文件
// - 只把与“+附件”相关的 UI + Picker + 预览 + 本地缓存整理放在这里
// - HomeChatView 只负责：
//   1) 显示按钮/预览
//   2) 在发送时把 pending items 上传并拼成 attachments
// =======================================================

// MARK: - Pending item

@MainActor
final class ChatPlusManager: ObservableObject {

    enum Origin: String, Sendable {
        case photoLibrary
        case camera
        case filesImage
        case file
    }

    struct PendingItem: Identifiable {
        let id: UUID
        let origin: Origin
        let kind: Kind

        enum Kind {
            case image(data: Data, preview: UIImage, filename: String, mime: String)
            case file(url: URL, filename: String, mime: String)
        }

        var filename: String {
            switch kind {
            case .image(_, _, let name, _): return name
            case .file(_, let name, _): return name
            }
        }

        var isImage: Bool {
            if case .image = kind { return true }
            return false
        }

        var isFile: Bool {
            if case .file = kind { return true }
            return false
        }

        var previewImage: UIImage? {
            switch kind {
            case .image(_, let preview, _, _): return preview
            case .file: return nil
            }
        }
    }

    enum PickerSheet: Identifiable {
        case photoLibrary
        case camera
        case files

        var id: Int {
            switch self {
            case .photoLibrary: return 1
            case .camera: return 2
            case .files: return 3
            }
        }
    }

    // MARK: Config

    var maxImageSelection: Int = 6
    var maxFileSelection: Int = 6

    // MARK: Published

    @Published var pending: [PendingItem] = []
    @Published var isLoading: Bool = false

    @Published var isMenuPresented: Bool = false
    @Published var activePicker: PickerSheet? = nil

    // MARK: Hooks

    /// 让外部（HomeChatView）把错误以 system message 形式显示
    var onErrorMessage: ((String) -> Void)?

    // MARK: State helpers

    var hasPending: Bool { !pending.isEmpty }

    func presentMenu() {
        isMenuPresented = true
    }

    func clear() {
        pending.removeAll()
    }

    func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// 发送时“取走并清空” pending
    func consumePending() -> [PendingItem] {
        let items = pending
        pending.removeAll()
        return items
    }

    // MARK: Menu actions

    func openPhotoLibrary() {
        activePicker = .photoLibrary
    }

    func openCamera() {
        activePicker = .camera
    }

    func openFiles() {
        activePicker = .files
    }

    // MARK: Picker result handlers

    func handlePickedImages(_ results: [PHPickerResult]) {
        activePicker = nil
        guard !results.isEmpty else {
            return
        }

        isLoading = true

        Task {
            defer {
                Task { @MainActor in
                    self.isLoading = false
                }
            }

            for r in results.prefix(maxImageSelection) {
                do {
                    if let image = try await Self.loadUIImage(from: r.itemProvider) {
                        let (data, preview) = Self.compressForChat(image: image)
                        await MainActor.run {
                            self.pending.append(
                                PendingItem(
                                    id: UUID(),
                                    origin: .photoLibrary,
                                    kind: .image(data: data,
                                                preview: preview,
                                                filename: "photo.jpg",
                                                mime: "image/jpeg")
                                )
                            )
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.onErrorMessage?("加载照片失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func handleCameraImage(_ image: UIImage?) {
        activePicker = nil
        guard let image else {
            return
        }

        isLoading = true
        Task {
            defer {
                Task { @MainActor in
                    self.isLoading = false
                }
            }

            let (data, preview) = Self.compressForChat(image: image)
            await MainActor.run {
                self.pending.append(
                    PendingItem(
                        id: UUID(),
                        origin: .camera,
                        kind: .image(data: data,
                                    preview: preview,
                                    filename: "camera.jpg",
                                    mime: "image/jpeg")
                    )
                )
            }
        }
    }


    func handlePickedDocuments(_ urls: [URL]) {
        activePicker = nil
        guard !urls.isEmpty else {
            return
        }

        isLoading = true

        Task {
            defer {
                Task { @MainActor in
                    self.isLoading = false
                }
            }

            for url in urls.prefix(maxFileSelection) {
                do {
                    let copied = try Self.copyToTempIfNeeded(original: url)
                    let type = Self.utType(for: copied)

                    // ✅ 图片（来自文件）直接按图片处理
                    if let type, type.conforms(to: .image),
                       let img = UIImage(contentsOfFile: copied.path) {
                        let (data, preview) = Self.compressForChat(image: img)
                        await MainActor.run {
                            self.pending.append(
                                PendingItem(
                                    id: UUID(),
                                    origin: .filesImage,
                                    kind: .image(data: data,
                                                preview: preview,
                                                filename: "file_image.jpg",
                                                mime: "image/jpeg")
                                )
                            )
                        }
                        continue
                    }

                    // ✅ 其它当文件
                    let mime = Self.mimeType(for: copied) ?? "application/octet-stream"
                    await MainActor.run {
                        self.pending.append(
                            PendingItem(
                                id: UUID(),
                                origin: .file,
                                kind: .file(url: copied,
                                            filename: copied.lastPathComponent,
                                            mime: mime)
                            )
                        )
                    }

                } catch {
                    await MainActor.run {
                        self.onErrorMessage?("选择文件失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func compressForChat(image: UIImage) -> (Data, UIImage) {
        // 统一压到 1600 边以内 + JPEG 0.78
        let maxDim: CGFloat = 1600
        let q: CGFloat = 0.78

        let w = image.size.width
        let h = image.size.height
        let maxSide = max(w, h)

        let scaled: UIImage
        if maxSide <= maxDim {
            scaled = image
        } else {
            let scale = maxDim / maxSide
            let newSize = CGSize(width: w * scale, height: h * scale)

            UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
            defer { UIGraphicsEndImageContext() }
            image.draw(in: CGRect(origin: .zero, size: newSize))
            scaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        }

        let data = scaled.jpegData(compressionQuality: q) ?? (image.jpegData(compressionQuality: q) ?? Data())
        let preview = UIImage(data: data) ?? scaled
        return (data, preview)
    }

    private static func loadUIImage(from provider: NSItemProvider) async throws -> UIImage? {
        // 优先 UIImage（最通用）
        if provider.canLoadObject(ofClass: UIImage.self) {
            return try await withCheckedThrowingContinuation { cont in
                provider.loadObject(ofClass: UIImage.self) { obj, err in
                    if let err { cont.resume(throwing: err); return }
                    cont.resume(returning: obj as? UIImage)
                }
            }
        }

        // 退回 Data
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await withCheckedThrowingContinuation { cont in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, err in
                    if let err { cont.resume(throwing: err); return }
                    guard let data, let ui = UIImage(data: data) else {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: ui)
                }
            }
        }

        return nil
    }


    private static func copyToTempIfNeeded(original: URL) throws -> URL {
        // Document picker 的 URL 可能需要 security scope
        let scoped = original.startAccessingSecurityScopedResource()
        defer {
            if scoped { original.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("solara-file-\(UUID().uuidString)-\(original.lastPathComponent)")
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        try fm.copyItem(at: original, to: dest)
        return dest
    }


    private static func utType(for url: URL) -> UTType? {
        if let t = UTType(filenameExtension: url.pathExtension) { return t }
        return nil
    }

    private static func mimeType(for url: URL) -> String? {
        if let t = utType(for: url), let m = t.preferredMIMEType { return m }
        return nil
    }
}

// MARK: - (+) Button (with menu + pickers)

struct ChatPlusButton: View {
    @ObservedObject var manager: ChatPlusManager
    var disabled: Bool = false

    private let uiGray = Color(white: 0.94)

    var body: some View {
        Button {
            HomeHaptics.light()
            manager.presentMenu()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.black.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(uiGray)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)

        // ✅ 菜单（干净，不占用额外 view 结构）
        .confirmationDialog(
            "添加",
            isPresented: $manager.isMenuPresented,
            titleVisibility: .visible
        ) {
            Button("照片（相册）") {
                manager.openPhotoLibrary()
            }
            Button("拍照") {
                manager.openCamera()
            }
            Button("文件") {
                manager.openFiles()
            }
            Button("取消", role: .cancel) {}
        }

        // ✅ 统一的 picker sheet
        .sheet(item: $manager.activePicker) { sheet in
            switch sheet {
            case .photoLibrary:
                ChatPlusPHPicker(mode: .images(limit: manager.maxImageSelection)) { results in
                    manager.handlePickedImages(results)
                }
                .ignoresSafeArea()

            case .camera:
                ChatPlusCameraPicker { image in
                    manager.handleCameraImage(image)
                }
                .ignoresSafeArea()

            case .files:
                ChatPlusDocumentPicker(limit: manager.maxFileSelection) { urls in
                    manager.handlePickedDocuments(urls)
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Preview Bar

struct ChatPlusPreviewBar: View {
    @ObservedObject var manager: ChatPlusManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            if manager.isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("正在准备附件…")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
            }

            let images = manager.pending.filter { $0.isImage }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { item in
                            if let ui = item.previewImage {
                                ZStack(alignment: .topTrailing) {
                                    ZStack(alignment: .bottomLeading) {
                                        Image(uiImage: ui)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 66, height: 66)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                        // ✅ 仅图片预览（不做视频帧）
                                    }

                                    Button {
                                        HomeHaptics.light()
                                        manager.remove(item.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.black.opacity(0.75))
                                            .background(Color.white.opacity(0.85).clipShape(Circle()))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            let files = manager.pending.filter { $0.isFile }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files) { item in
                        ChatPlusFileRow(
                            filename: item.filename,
                            onRemove: {
                                HomeHaptics.light()
                                manager.remove(item.id)
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct ChatPlusFileRow: View {
    let filename: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.gray.opacity(0.85))

            Text(filename)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .lineLimit(1)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.gray.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - PHPicker

struct ChatPlusPHPicker: UIViewControllerRepresentable {

    enum Mode {
        case images(limit: Int)

        var selectionLimit: Int {
            switch self {
            case .images(let l): return max(1, l)
            }
        }

        var filter: PHPickerFilter {
            return .images
        }
    }

    let mode: Mode
    let onComplete: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = mode.filter
        cfg.selectionLimit = mode.selectionLimit

        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PHPickerResult]) -> Void
        init(onComplete: @escaping ([PHPickerResult]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onComplete(results)
        }
    }
}

// MARK: - Camera Picker

struct ChatPlusCameraPicker: UIViewControllerRepresentable {
    let onComplete: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()

        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // 没有相机时回退到相册（不强行报错）
            picker.sourceType = .photoLibrary
        }

        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onComplete: (UIImage?) -> Void
        init(onComplete: @escaping (UIImage?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onComplete(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            picker.dismiss(animated: true)
            onComplete(img)
        }
    }
}

// MARK: - Document Picker

struct ChatPlusDocumentPicker: UIViewControllerRepresentable {

    let limit: Int
    let onComplete: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(limit: limit, onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 允许任意文件：.data
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data], asCopy: false)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = true
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let limit: Int
        let onComplete: ([URL]) -> Void
        init(limit: Int, onComplete: @escaping ([URL]) -> Void) {
            self.limit = limit
            self.onComplete = onComplete
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete([])
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(Array(urls.prefix(max(1, limit))))
        }
    }
}

// MARK: - Uploader (统一：image/audio/file)

struct UploadedMedia: Codable {
    let id: String
    let mime: String?
    let url: String?
}

final class MediaUploadService {

    func uploadImage(
        apiBase: String,
        data: Data,
        filename: String = "photo.jpg",
        mime: String = "image/jpeg"
    ) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/image")!
        return try await uploadMultipart(
            url: url,
            fieldName: "file",
            fileName: filename,
            mime: mime,
            data: data,
            timeout: 90
        )
    }

    func uploadAudio(
        apiBase: String,
        fileURL: URL,
        filename: String = "voice.m4a",
        mime: String = "audio/mp4"
    ) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/audio")!
        let data = try Data(contentsOf: fileURL)
        return try await uploadMultipart(
            url: url,
            fieldName: "file",
            fileName: filename,
            mime: mime,
            data: data,
            timeout: 180
        )
    }

    /// ✅ 文件上传：默认走 /upload/file
    /// - 如果你后端路径不同，直接改这里即可（不要在各处散落）
    func uploadFile(
        apiBase: String,
        fileURL: URL,
        filename: String? = nil,
        mime: String? = nil
    ) async throws -> UploadedMedia {
        let url = URL(string: apiBase + "/upload/file")!
        let data = try Data(contentsOf: fileURL)

        let name = (filename?.isEmpty == false ? filename! : fileURL.lastPathComponent)
        let m = (mime?.isEmpty == false ? mime! : (UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))

        return try await uploadMultipart(
            url: url,
            fieldName: "file",
            fileName: name,
            mime: m,
            data: data,
            timeout: 180
        )
    }

    private func uploadMultipart(
        url: URL,
        fieldName: String,
        fileName: String,
        mime: String,
        data: Data,
        timeout: TimeInterval
    ) async throws -> UploadedMedia {

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "MediaUploadService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "upload 无响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: respData, encoding: .utf8) ?? ""
            throw NSError(domain: "MediaUploadService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "upload 失败 \(http.statusCode): \(bodyText)"])
        }

        return try JSONDecoder().decode(UploadedMedia.self, from: respData)
    }
}


