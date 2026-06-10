import Foundation
import Photos
import Vision
import UIKit

// MARK: - PhotoGroupingEngine
// Groups photos that were taken in close time proximity (same scene/burst).
// Strategy:
//   1. Sort assets by creationDate.
//   2. Cluster assets within a configurable time window (default 10 seconds).
//   3. Optionally refine clusters using Vision image similarity (feature prints).

actor PhotoGroupingEngine {

    // Maximum seconds between shots to be considered the "same scene"
    var timeWindowSeconds: Double = 60.0

    // Minimum cluster size to surface as a group (skip singletons)
    var minimumGroupSize: Int = 2

    // Whether to run Vision feature-print similarity refinement
    var useVisionSimilarity: Bool = true

    // MARK: - Public API

    func groupAssets(_ assets: [PHAsset]) async -> [PhotoGroup] {
        let sorted = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        var timeClusters = clusterByTime(sorted)

        if useVisionSimilarity {
            timeClusters = await refineWithVision(timeClusters)
        }

        return timeClusters.filter { $0.assets.count >= minimumGroupSize }
    }

    // MARK: - Time Clustering

    private func clusterByTime(_ sorted: [PHAsset]) -> [PhotoGroup] {
        guard !sorted.isEmpty else { return [] }

        var groups: [PhotoGroup] = []
        var current: [PHAsset] = [sorted[0]]

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]

            let prevDate = prev.creationDate ?? .distantPast
            let currDate = curr.creationDate ?? .distantPast
            let gap = currDate.timeIntervalSince(prevDate)

            if gap <= timeWindowSeconds {
                current.append(curr)
            } else {
                groups.append(PhotoGroup(assets: current))
                current = [curr]
            }
        }
        groups.append(PhotoGroup(assets: current))
        return groups
    }

    // MARK: - Vision Similarity Refinement
    // 各時間クラスタ内でVision類似度を使ってさらに分割する
    // （見た目が違う写真が同じ時間帯に撮られた場合に分離）

    private func refineWithVision(_ groups: [PhotoGroup]) async -> [PhotoGroup] {
        var refined: [PhotoGroup] = []

        for group in groups {
            guard group.assets.count >= 2 else {
                refined.append(group)
                continue
            }

            let prints = await computeFeaturePrints(group.assets)
            let validCount = prints.compactMap { $0 }.count

            // Visionが失敗した場合は時間クラスタをそのまま使う
            if validCount < 2 {
                refined.append(group)
                continue
            }

            let subGroups = clusterByFeaturePrints(group.assets, prints: prints)
            refined.append(contentsOf: subGroups)
        }

        return refined
    }

    private func computeFeaturePrints(_ assets: [PHAsset]) async -> [VNFeaturePrintObservation?] {
        var results: [VNFeaturePrintObservation?] = Array(repeating: nil, count: assets.count)

        await withTaskGroup(of: (Int, VNFeaturePrintObservation?).self) { group in
            for (index, asset) in assets.enumerated() {
                group.addTask {
                    let print = await Self.featurePrint(for: asset)
                    return (index, print)
                }
            }
            for await (index, print) in group {
                results[index] = print
            }
        }

        return results
    }

    private static func featurePrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard let cgImage = image?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = VNGenerateImageFeaturePrintRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                continuation.resume(returning: request.results?.first as? VNFeaturePrintObservation)
            }
        }
    }

    private func clusterByFeaturePrints(
        _ assets: [PHAsset],
        prints: [VNFeaturePrintObservation?]
    ) -> [PhotoGroup] {
        // Greedy single-linkage clustering with a distance threshold
        let threshold: Float = 1.0
        var clusters: [[Int]] = []
        var assigned = Set<Int>()

        for i in 0..<assets.count {
            if assigned.contains(i) { continue }
            var cluster = [i]
            assigned.insert(i)

            for j in (i + 1)..<assets.count {
                if assigned.contains(j) { continue }
                guard let pi = prints[i], let pj = prints[j] else { continue }
                var dist: Float = 0
                if (try? pi.computeDistance(&dist, to: pj)) != nil, dist < threshold {
                    cluster.append(j)
                    assigned.insert(j)
                }
            }

            clusters.append(cluster)
        }

        return clusters.map { indices in
            PhotoGroup(assets: indices.map { assets[$0] })
        }
    }
}
