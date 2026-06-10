import Foundation
import Photos
import Combine

@MainActor
class CuratorViewModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var isAnalyzing = false
    @Published var progress: Double = 0
    @Published var selectedForDeletion: Set<UUID> = []

    private let groupingEngine = PhotoGroupingEngine()
    private let scorer = PhotoQualityScorer()

    // MARK: - Analysis Pipeline

    func analyze(assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        isAnalyzing = true
        progress = 0
        defer { isAnalyzing = false }

        // Step 1: Group similar photos
        progress = 0.1
        var rawGroups = await groupingEngine.groupAssets(assets)
        progress = 0.4

        // Step 2: Score each group and find best asset
        var scored: [PhotoGroup] = []
        for (i, group) in rawGroups.enumerated() {
            let ranks = await scorer.rankAssets(group.assets)
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

        // Step 3: Pre-select all non-best assets for deletion
        selectedForDeletion = Set(scored.map { $0.id })
        groups = scored
        progress = 1.0
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
        } catch {
            print("Delete failed: \(error)")
        }
    }

    func delete(assets: [PHAsset]) async {
        do {
            try await PhotoLibraryManager.shared.deleteAssets(assets)
            await PhotoLibraryManager.shared.fetchAllPhotos()
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
}
