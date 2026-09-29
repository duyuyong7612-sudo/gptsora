// PhotoSaveService.swift
// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a2b8fcc5924040f7664ba20e06bd140e4114f9e7d33074092cb0122052f471b1"
// Source-SHA256: "5fc41c2feb7593563e9647eaff53d59136b4a126f0eb197b41ba795c82a16441"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Photos

enum PhotoSaveError: Error {
    case noPermission
    case saveFailed
}

final class PhotoSaveService {
    static let shared = PhotoSaveService()
    private init() {}

    /// 保存本地视频到系统相册
    func saveVideoToAlbum(fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        // 1. 先申请权限（iOS 14+ 推荐 .addOnly）
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        completion(.failure(PhotoSaveError.noPermission))
                    }
                    return
                }
                self.save(fileURL: fileURL, completion: completion)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    DispatchQueue.main.async {
                        completion(.failure(PhotoSaveError.noPermission))
                    }
                    return
                }
                self.save(fileURL: fileURL, completion: completion)
            }
        }
    }

    private func save(fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? PhotoSaveError.saveFailed))
                }
            }
        })
    }
}

