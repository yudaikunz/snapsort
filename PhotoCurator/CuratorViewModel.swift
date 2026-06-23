import Foundation
import Photos
import Combine

@MainActor
class CuratorViewModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var isAnalyzing = false
    @Published var progress: Double = 0
    @Published var selectedForDeletion: Set<UUID> = []
    /// 直近の分析実施日時（キャッシュ復元時にも設定される）
    @Published var lastAnalysisDate: Date?

    private let groupingEngine = PhotoGroupingEngine()
    private let scorer = PhotoQualityScorer()
    private var analysisTask: Task<Void, Never>?

    // MARK: - Analysis Pipeline

    /// 分析を開始する（既存の分析が走っていればキャンセルしてから開始）
    func startAnalysis(assets: [PHAsset]) {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            await self?.analyze(assets: assets)
        }
    }

    /// 実行中の分析をキャンセルする
    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        progress = 0
    }

    func analyze(assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        isAnalyzing = true
        progress = 0
        defer {
            isAnalyzing = false
            analysisTask = nil
        }

        // Step 1: Group similar photos
        progress = 0.1
        let rawGroups = await groupingEngine.groupAssets(assets)
        if Task.isCancelled { return }
        progress = 0.4

        // Step 2: Score each group and find best asset
        var scored: [PhotoGroup] = []
        for (i, group) in rawGroups.enumerated() {
            if Task.isCancelled { return }
            let ranks = await scorer.rankAssets(group.assets)
            if Task.isCancelled { return }
            if let best = ranks.first,
               let bestIndex = group.assets.firstIndex(where: { $0.localIdentifier == best.asset.localIdentifier }) {
                var updated = group
                updated.bestAssetIndex = bestIndex
                updated.bestScore = best
                scored.append(updated)
            } else {
                scored.append(group)
            }
            progress = 0.4 + 0.5 * (Double(i + 1) / Double(rawGroups.count))
        }

        if Task.isCancelled { return }

        // Step 3: Pre-select all non-best assets for deletion
        selectedForDeletion = Set(scored.map { $0.id })
        groups = scored
        lastAnalysisDate = Date()
        progress = 1.0
        saveCache()
    }

    // MARK: - Deletion

    func deleteSelectedDuplicates() async {
        let assetsToDelete = groups
            .filter { selectedForDeletion.contains($0.id) }
            .flatMap { group in
                let keep = group.effectiveKeepIndices
                return group.assets.enumerated()
                    .filter { !keep.contains($0.offset) }
                    .map { $0.element }
            }
        await delete(assets: assetsToDelete)
    }

    func deleteFromGroup(groupID: UUID, assets: [PHAsset]) async {
        do {
            let deletedIDs = Set(assets.map { $0.localIdentifier })
            try await PhotoLibraryManager.shared.deleteAssets(assets)
            // グループを即時更新（再分析なし）
            groups = groups.compactMap { group in
                guard group.id == groupID else { return group }
                var updated = group
                updated.assets = group.assets.filter { !deletedIDs.contains($0.localIdentifier) }
                guard updated.assets.count >= 2 else { return nil }
                // bestAssetIndex を再マッピング
                let oldBest = group.assets[group.bestAssetIndex]
                if deletedIDs.contains(oldBest.localIdentifier) {
                    updated.bestAssetIndex = 0
                } else {
                    updated.bestAssetIndex = updated.assets.firstIndex(where: {
                        $0.localIdentifier == oldBest.localIdentifier
                    }) ?? 0
                }
                // keepIndices を再マッピング
                let oldKeep = group.effectiveKeepIndices.compactMap { i -> String? in
                    guard i < group.assets.count else { return nil }
                    return group.assets[i].localIdentifier
                }
                updated.keepIndices = Set(
                    oldKeep.compactMap { id -> Int? in
                        updated.assets.firstIndex(where: { $0.localIdentifier == id })
                    }
                )
                return updated
            }
            selectedForDeletion = selectedForDeletion.filter { id in
                groups.contains(where: { $0.id == id })
            }
            saveCache()
        } catch {
            print("Delete failed: \(error)")
        }
    }

    func delete(assets: [PHAsset]) async {
        do {
            try await PhotoLibraryManager.shared.deleteAssets(assets)
            await PhotoLibraryManager.shared.fetchAllPhotos()
            // 一括削除後は結果が古くなるためキャッシュを破棄（次回は再分析）
            groups = []
            selectedForDeletion = []
            saveCache()
        } catch {
            print("Delete failed: \(error)")
        }
    }

    // MARK: - Selection

    func toggleSelection(groupID: UUID) {
        if selectedForDeletion.contains(groupID) {
            selectedForDeletion.remove(groupID)
        } else {
            selectedForDeletion.insert(groupID)
        }
    }

    // MARK: - Result Cache
    //
    // 分析結果（グループ構成・ベスト写真・スコア・残す選択）を端末に保存し、
    // 起動時に復元することで、毎回フル再分析する必要をなくす。
    // 写真は localIdentifier で参照し、復元時に存在しないものは除外する。

    private struct CachedScore: Codable {
        let sharpness, exposure, faceQuality, eyesOpen: Double
        let hasFace: Bool
    }
    private struct CachedGroup: Codable {
        let assetIDs: [String]
        let bestAssetID: String
        let bestScore: CachedScore?
        let keepIDs: [String]
    }
    private struct AnalysisSnapshot: Codable {
        let date: Date
        let groups: [CachedGroup]
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("analysis_cache.json")
    }

    private func saveCache() {
        guard !groups.isEmpty else {
            try? FileManager.default.removeItem(at: cacheURL)
            return
        }
        let cached: [CachedGroup] = groups.compactMap { g in
            guard g.assets.indices.contains(g.bestAssetIndex) else { return nil }
            let keepIDs = g.keepIndices.compactMap { g.assets.indices.contains($0) ? g.assets[$0].localIdentifier : nil }
            let score = g.bestScore.map {
                CachedScore(sharpness: $0.sharpness, exposure: $0.exposure,
                            faceQuality: $0.faceQuality, eyesOpen: $0.eyesOpen, hasFace: $0.hasFace)
            }
            return CachedGroup(
                assetIDs: g.assets.map { $0.localIdentifier },
                bestAssetID: g.assets[g.bestAssetIndex].localIdentifier,
                bestScore: score,
                keepIDs: keepIDs
            )
        }
        let snapshot = AnalysisSnapshot(date: lastAnalysisDate ?? Date(), groups: cached)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// 保存済みの分析結果を復元する（未分析・分析中・既に結果がある場合は何もしない）。
    func loadCachedResults() async {
        guard groups.isEmpty, !isAnalyzing,
              let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(AnalysisSnapshot.self, from: data),
              !snapshot.groups.isEmpty else { return }

        var rebuilt: [PhotoGroup] = []
        for cg in snapshot.groups {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: cg.assetIDs, options: nil)
            var byID: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            // 元の並び順を維持しつつ、削除済み（取得できない）写真は除外
            let assets = cg.assetIDs.compactMap { byID[$0] }
            guard assets.count >= 2 else { continue }

            var group = PhotoGroup(assets: assets)
            group.bestAssetIndex = assets.firstIndex { $0.localIdentifier == cg.bestAssetID } ?? 0
            if let cs = cg.bestScore {
                group.bestScore = PhotoQualityScore(
                    asset: assets[group.bestAssetIndex],
                    sharpness: cs.sharpness, exposure: cs.exposure,
                    faceQuality: cs.faceQuality, hasFace: cs.hasFace, eyesOpen: cs.eyesOpen
                )
            }
            group.keepIndices = Set(cg.keepIDs.compactMap { id in
                assets.firstIndex { $0.localIdentifier == id }
            })
            rebuilt.append(group)
        }

        guard !rebuilt.isEmpty else { return }
        groups = rebuilt
        lastAnalysisDate = snapshot.date
        selectedForDeletion = Set(rebuilt.map { $0.id })
        // 復元中に消えた写真があればキャッシュを更新
        if rebuilt.count != snapshot.groups.count { saveCache() }
    }
}
