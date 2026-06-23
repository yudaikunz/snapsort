import Foundation
import Photos
import Combine

// MARK: - FavoritesStore
//
// PHAsset.isFavorite のローカルミラー。
// Photos フレームワーク経由でお気に入りを設定し、即時 UI 更新のため
// ローカルに Set<String> (localIdentifier) を保持する。

final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favoriteIDs: Set<String> = []

    private init() {}

    // MARK: - Sync

    /// PHAsset のリストから現在のお気に入り状態を同期する。
    /// 大量の写真（数千〜万枚）でもメインスレッドを塞がないよう、
    /// フィルタリングはバックグラウンドで行い、結果のみメインで反映する。
    func syncFromAssets(_ assets: [PHAsset]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = Set(assets.filter { $0.isFavorite }.map { $0.localIdentifier })
            DispatchQueue.main.async {
                if ids != self.favoriteIDs { self.favoriteIDs = ids }
            }
        }
    }

    // MARK: - Toggle

    /// お気に入りを切り替える（楽観的 UI 更新 → Photos 変更 → 失敗時ロールバック）
    func toggle(asset: PHAsset) async {
        let wasAlreadyFav = favoriteIDs.contains(asset.localIdentifier)
        // 即時 UI 更新（メインスレッド）
        await MainActor.run {
            if wasAlreadyFav { favoriteIDs.remove(asset.localIdentifier) }
            else             { favoriteIDs.insert(asset.localIdentifier) }
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = !wasAlreadyFav
            }
        } catch {
            // 失敗時ロールバック
            await MainActor.run {
                if wasAlreadyFav { favoriteIDs.insert(asset.localIdentifier) }
                else             { favoriteIDs.remove(asset.localIdentifier) }
            }
        }
    }

    // MARK: - Query

    func isFavorite(_ id: String) -> Bool {
        favoriteIDs.contains(id)
    }
}
