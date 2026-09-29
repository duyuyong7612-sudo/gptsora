// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a68731a40c7ebd65d78df778260ef757a37ee1e15f2da5db2682ee628e8b5bc9"
// Source-SHA256: "708f13c2fb7b807b2cebfc366355bf77a4b24812677f3e3714d2fe48265b58f9"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Photos

enum PhotoSaveError: Error {
    case noPermission
    case fileMissing
    case saveFailed
}

final class PhotoSaveService {

    static let shared = PhotoSaveService()
    private init() {}

    // MARK: - Public (Callback)

    /// 保存本地视频到系统相册（不会多余弹权限）
    func saveVideoToAlbum(
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {

        // 0️⃣ 文件校验（提前失败，避免走 Photos API）
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.async {
                completion(.failure(PhotoSaveError.fileMissing))
            }
            return
        }

        // 1️⃣ 检查权限状态
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            handle(status: status, fileURL: fileURL, completion: completion)
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            handleLegacy(status: status, fileURL: fileURL, completion: completion)
        }
    }

    // MARK: - Public (Async/Await)

    @available(iOS 13.0, *)
    func saveVideoToAlbum(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            saveVideoToAlbum(fileURL: fileURL) { result in
                cont.resume(with: result)
            }
        }
    }

    // MARK: - Authorization Handling

    @available(iOS 14, *)
    private func handle(
        status: PHAuthorizationStatus,
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch status {
        case .authorized, .limited:
            save(fileURL: fileURL, completion: completion)

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    self.save(fileURL: fileURL, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(PhotoSaveError.noPermission))
                    }
                }
            }

        default:
            DispatchQueue.main.async {
                completion(.failure(PhotoSaveError.noPermission))
            }
        }
    }

    private func handleLegacy(
        status: PHAuthorizationStatus,
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch status {
        case .authorized:
            save(fileURL: fileURL, completion: completion)

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { newStatus in
                if newStatus == .authorized {
                    self.save(fileURL: fileURL, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(PhotoSaveError.noPermission))
                    }
                }
            }

        default:
            DispatchQueue.main.async {
                completion(.failure(PhotoSaveError.noPermission))
            }
        }
    }

    // MARK: - Save

    private func save(
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(
                atFileURL: fileURL
            )
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? PhotoSaveError.saveFailed))
                }
            }
        }
    }
}

