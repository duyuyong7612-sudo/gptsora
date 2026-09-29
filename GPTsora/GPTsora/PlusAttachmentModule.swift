// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e0ab25907a404f4e205a10cac26fd549c97f3614605882cc663eaa7e685f171c"
// Source-SHA256: "e512f41a67e214caec7ee110259aa55225bb0115334a83931f1fe1f66a1c1e84"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import UIKit

// MARK: - PlusAttachmentModule
// Single-file, clean module for (+) attachments:
// Photos (library), Camera, Files, Video (frame extraction)
// All logic lives here. Host view only receives AttachmentDrafts.

public struct AttachmentDraft: Identifiable {
    public enum Kind { case image(UIImage), file(URL), videoFrames([UIImage]) }
    public let id = UUID()
    public let kind: Kind
}

public struct PlusAttachmentButton: View {
    public var maxPhotoCount: Int = 6
    public var onAdd: ([AttachmentDraft]) -> Void

    @State private var showMenu = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pickedVideos: [PhotosPickerItem] = []

    public init(maxPhotoCount: Int = 6, onAdd: @escaping ([AttachmentDraft]) -> Void) {
        self.maxPhotoCount = maxPhotoCount
        self.onAdd = onAdd
    }

    public var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.black.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(Color(white: 0.92))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .confirmationDialog("添加内容", isPresented: $showMenu) {
            Button("相册照片") { /* Photos */ }
            Button("拍照") { showCamera = true }
            Button("文件") { showFiles = true }
            Button("视频（转帧）") { /* Videos */ }
        }

        // Photos
        .photosPicker(isPresented: Binding(
            get: { false },
            set: { _ in }
        ), selection: $pickedPhotos, maxSelectionCount: maxPhotoCount, matching: .images)

        .onChange(of: pickedPhotos) { items in
            Task {
                var drafts: [AttachmentDraft] = []
                for it in items {
                    if let data = try? await it.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        drafts.append(.init(kind: .image(img)))
                    }
                }
                if !drafts.isEmpty { onAdd(drafts) }
                pickedPhotos.removeAll()
            }
        }

        // Camera
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let image {
                    onAdd([.init(kind: .image(image))])
                }
            }
        }

        // Files
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                onAdd([.init(kind: .file(url))])
            case .failure:
                break
            }
        }
    }
}

// MARK: - CameraPicker
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { self.parent.onImage(img) }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.parent.onImage(nil) }
        }
    }
}

