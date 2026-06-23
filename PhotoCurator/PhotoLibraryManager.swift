import Foundation
import Photos
import UIKit
import AVFoundation
import Combine
import Vision

// MARK: - Models

struct PhotoGroup: Identifiable {
    let id = UUID()
    var assets: [PHAsset]
    var bestAssetIndex: Int = 0
    var bestScore: PhotoQualityScore?
    var keepIndices: Set<Int> = []  // 残す写真のインデックス（空の場合はbestAssetIndexのみ）

    var bestAsset: PHAsset { assets[bestAssetIndex] }
    var effectiveKeepIndices: Set<Int> { keepIndices.isEmpty ? [bestAssetIndex] : keepIndices }
    var duplicateCount: Int { assets.count - effectiveKeepIndices.count }
}

// MARK: - PhotoLibraryManager

@MainActor
class PhotoLibraryManager: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var allAssets: [PHAsset] = []
    @Published var isLoading = false
    @Published var allVideoAssets: [PHAsset] = []
    @Published var isLoadingVideos = false

    static let shared = PhotoLibraryManager()
    private init() {}

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await fetchAllPhotos()
            await fetchAllVideos()
        }
    }

    func checkCurrentAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func fetchAllPhotos() async {
        isLoading = true
        defer { isLoading = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: fetchOptions)

        // enumerateObjects はブロッキング処理のためバックグラウンドで実行
        let assets = await Task.detached(priority: .userInitiated) {
            var collected: [PHAsset] = []
            collected.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                collected.append(asset)
            }
            return collected
        }.value

        allAssets = assets
    }

    func fetchAllVideos() async {
        guard !isLoadingVideos else { return }
        isLoadingVideos = true
        defer { isLoadingVideos = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: fetchOptions)

        let assets = await Task.detached(priority: .userInitiated) {
            var collected: [PHAsset] = []
            collected.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in collected.append(asset) }
            return collected
        }.value

        allVideoAssets = assets
    }

    func loadAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: avAsset)
            }
        }
    }

    func deleteAssets(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }
    }

    func loadImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            // iCloud 写真などでハンドラが複数回呼ばれても継続を1度だけ resume する
            // （2回 resume するとクラッシュするため）。
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
