import Foundation
import Photos
import UIKit
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

    static let shared = PhotoLibraryManager()
    private init() {}

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await fetchAllPhotos()
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
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        allAssets = assets
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

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
