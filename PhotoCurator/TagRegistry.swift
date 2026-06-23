import Foundation
import SwiftUI
import Combine
import Photos

// MARK: - Tag Color

extension Color {
    /// タグカラーパレット（インデックス 0〜5）
    static func tagColor(_ index: Int) -> Color {
        switch index % 6 {
        case 0: return .indigo
        case 1: return Color(red: 1, green: 0.27, blue: 0.23)  // deleteRed 相当
        case 2: return .orange
        case 3: return Color(red: 0.2, green: 0.78, blue: 0.35) // keepGreen 相当
        case 4: return .purple
        default: return .pink
        }
    }

    static let tagColorNames = ["インディゴ", "レッド", "オレンジ", "グリーン", "パープル", "ピンク"]
}

// MARK: - RegisteredTag

struct RegisteredTag: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int      // 0〜5
    var photoIDs: [String]   // PHAsset.localIdentifier のリスト（高速フィルタ用のローカルミラー）
    var albumID: String?     // 連動する iOS アルバム(PHAssetCollection)の localIdentifier

    init(id: UUID = UUID(), name: String, colorIndex: Int = 0,
         photoIDs: [String] = [], albumID: String? = nil) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.photoIDs = photoIDs
        self.albumID = albumID
    }
}

// MARK: - TagRegistry
//
// タグは iOS 標準写真アプリの「ユーザーアルバム」(PHAssetCollection) と連動する。
// - 色など写真アプリに持てない情報、および高速フィルタ用の photoIDs はローカル(UserDefaults)に保持。
// - タグ操作は即座にローカルへ反映（UI即応）し、写真アプリ側へはベストエフォートで同期する。
// - 写真への書き込み権限がない／限定アクセスの場合はローカルのみで動作（フォールバック）。

final class TagRegistry: ObservableObject {
    static let shared = TagRegistry()

    @Published private(set) var tags: [RegisteredTag] = []

    private let udKey = "photoCurator.registeredTags"

    private init() {
        load()
        // 既存タグ（旧バージョンで作成、アルバム未連動）を写真アプリのアルバムへ移行
        Task { await migrateToAlbumsIfNeeded() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([RegisteredTag].self, from: data)
        else { return }
        tags = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    // MARK: - Tag CRUD

    @discardableResult
    func addTag(name: String, colorIndex: Int = 0) -> RegisteredTag {
        let tag = RegisteredTag(name: name, colorIndex: colorIndex)
        tags.append(tag)
        save()
        let tagID = tag.id
        Task { await createAlbum(for: tagID, title: name) }
        return tag
    }

    /// タグを削除する。連動アルバムも削除する（写真本体は削除されない）。
    func deleteTag(id: UUID) {
        let albumID = tags.first(where: { $0.id == id })?.albumID
        tags.removeAll { $0.id == id }
        save()
        if let albumID {
            Task { await deleteAlbum(albumID) }
        }
    }

    // MARK: - Tagging

    func tagPhoto(assetID: String, tagID: UUID) {
        guard let i = tags.firstIndex(where: { $0.id == tagID }) else { return }
        guard !tags[i].photoIDs.contains(assetID) else { return }
        tags[i].photoIDs.append(assetID)
        save()
        let albumID = tags[i].albumID
        Task { await addAssets([assetID], toAlbumLocalID: albumID) }
    }

    func untagPhoto(assetID: String, tagID: UUID) {
        guard let i = tags.firstIndex(where: { $0.id == tagID }) else { return }
        tags[i].photoIDs.removeAll { $0 == assetID }
        save()
        let albumID = tags[i].albumID
        Task { await removeAssets([assetID], fromAlbumLocalID: albumID) }
    }

    func isTagged(assetID: String, tagID: UUID) -> Bool {
        tags.first(where: { $0.id == tagID })?.photoIDs.contains(assetID) ?? false
    }

    func appliedTags(for assetID: String) -> [RegisteredTag] {
        tags.filter { $0.photoIDs.contains(assetID) }
    }

    // MARK: - Photos Album Sync (best effort)

    private var canWriteAlbums: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// タグ用のアルバムを作成し、localIdentifier を保存。既存の photoIDs もアルバムへ追加する。
    private func createAlbum(for tagID: UUID, title: String) async {
        guard canWriteAlbums else { return }

        var placeholder: PHObjectPlaceholder?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                placeholder = req.placeholderForCreatedAssetCollection
            }
        } catch {
            return  // 作成失敗時はローカルのみで動作
        }

        guard let albumID = placeholder?.localIdentifier else { return }

        let existingPhotoIDs: [String] = await MainActor.run {
            guard let i = self.tags.firstIndex(where: { $0.id == tagID }) else { return [] }
            self.tags[i].albumID = albumID
            self.save()
            return self.tags[i].photoIDs
        }

        if !existingPhotoIDs.isEmpty {
            await addAssets(existingPhotoIDs, toAlbumLocalID: albumID)
        }
    }

    private func addAssets(_ assetIDs: [String], toAlbumLocalID albumID: String?) async {
        guard canWriteAlbums, let albumID, !assetIDs.isEmpty,
              let album = fetchAlbum(albumID) else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest(for: album)
            req?.addAssets(assets)
        }
    }

    private func removeAssets(_ assetIDs: [String], fromAlbumLocalID albumID: String?) async {
        guard canWriteAlbums, let albumID, !assetIDs.isEmpty,
              let album = fetchAlbum(albumID) else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest(for: album)
            req?.removeAssets(assets)
        }
    }

    /// アルバムを削除する（写真本体は削除されない）。
    private func deleteAlbum(_ albumID: String) async {
        guard canWriteAlbums, let album = fetchAlbum(albumID) else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
    }

    private func fetchAlbum(_ localID: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localID], options: nil).firstObject
    }

    private func migrateToAlbumsIfNeeded() async {
        guard canWriteAlbums else { return }
        let pending: [(id: UUID, name: String)] = await MainActor.run {
            self.tags.filter { $0.albumID == nil }.map { ($0.id, $0.name) }
        }
        for tag in pending {
            await createAlbum(for: tag.id, title: tag.name)
        }
    }
}
