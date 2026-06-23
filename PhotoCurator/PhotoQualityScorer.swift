import Foundation
import Photos
import Vision
import UIKit

// MARK: - PhotoQualityScore

struct PhotoQualityScore: @unchecked Sendable {
    let asset: PHAsset
    let sharpness: Double        // 0–1  (higher = sharper)
    let exposure: Double         // 0–1  (closer to 1 = well exposed)
    let faceQuality: Double      // 0–1  (higher = better face quality; 0 if no face)
    let hasFace: Bool
    let eyesOpen: Double         // 0–1  (1 = eyes open, 0 = eyes closed; 1 if no face)

    nonisolated var total: Double {
        let faceWeight: Double = hasFace ? 0.4 : 0.0
        let baseWeight: Double = hasFace ? 0.6 : 1.0
        let base = baseWeight * (sharpness * 0.6 + exposure * 0.4) + faceWeight * faceQuality
        // 目つぶりは強いペナルティ（顔がある場合のみ）
        let eyePenalty = hasFace ? (1.0 - eyesOpen) * 0.5 : 0.0
        return max(0, base - eyePenalty)
    }

    func recommendationReasons(lm: LanguageManager) -> [String] {
        var reasons: [String] = []
        if sharpness > 0.6  { reasons.append(lm.s("鮮明", "Sharp")) }
        if exposure > 0.65  { reasons.append(lm.s("露出良好", "Good Exposure")) }
        if hasFace && faceQuality > 0.6 { reasons.append(lm.s("顔の品質が高い", "High Face Quality")) }
        if hasFace && eyesOpen > 0.6    { reasons.append(lm.s("目が開いている", "Eyes Open")) }
        if hasFace && eyesOpen < 0.4    { reasons.append(lm.s("⚠️ 目つぶりあり", "⚠️ Eyes Closed")) }
        if reasons.isEmpty { reasons.append(lm.s("総合スコアが最高", "Best Overall Score")) }
        return reasons
    }
}

// MARK: - PhotoQualityScorer

actor PhotoQualityScorer {

    // 同時にスコアリングする枚数の上限（メモリ保護）。
    // 各スコアリングは画像読み込み + 複数のVision/CPUタスクを伴うため、
    // 無制限に並列化すると大きなグループでメモリが枯渇する。
    private let maxConcurrentScores = 4

    // MARK: - Public API

    /// Score all assets in a group and return them sorted best-first.
    func rankAssets(_ assets: [PHAsset]) async -> [PhotoQualityScore] {
        var scores: [PhotoQualityScore] = []

        await withTaskGroup(of: PhotoQualityScore?.self) { group in
            var nextIndex = 0
            let prime = min(maxConcurrentScores, assets.count)
            for _ in 0..<prime {
                let asset = assets[nextIndex]; nextIndex += 1
                group.addTask { await self.score(asset) }
            }

            for await result in group {
                if let s = result { scores.append(s) }
                if nextIndex < assets.count {
                    let asset = assets[nextIndex]; nextIndex += 1
                    group.addTask { await self.score(asset) }
                }
            }
        }

        return scores.sorted { $0.total > $1.total }
    }

    // MARK: - Single Asset Scoring

    func score(_ asset: PHAsset) async -> PhotoQualityScore {
        guard let image = await loadThumbnail(asset) else {
            return PhotoQualityScore(asset: asset, sharpness: 0, exposure: 0, faceQuality: 0, hasFace: false, eyesOpen: 1.0)
        }

        async let sharpnessTask = measureSharpness(image)
        async let exposureTask = measureExposure(image)
        async let faceTask = measureFaceQuality(image)
        async let eyeTask = measureEyeOpenness(image)

        let sharpness = await sharpnessTask
        let exposure = await exposureTask
        let (faceQuality, hasFace) = await faceTask
        let eyesOpen = await eyeTask

        return PhotoQualityScore(
            asset: asset,
            sharpness: sharpness,
            exposure: exposure,
            faceQuality: faceQuality,
            hasFace: hasFace,
            eyesOpen: eyesOpen
        )
    }

    // MARK: - Image Loading

    private func loadThumbnail(_ asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            // PHImageManager は iCloud 写真などでハンドラを複数回呼ぶことがある。
            // 継続を2回 resume するとクラッシュするため、中間（劣化）結果を無視し
            // 最終結果で一度だけ resume する。
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    // MARK: - Sharpness (Laplacian Variance via VNDetectRectanglesRequest as proxy)
    // We use Vision's image-based feature approach: request a high-quality
    // classification and read the confidence as a sharpness proxy, then
    // fall back to a simple pixel-variance method.

    private func measureSharpness(_ image: CGImage) async -> Double {
        // Use VNGenerateAttentionBasedSaliencyImageRequest as a proxy;
        // alternatively, compute variance of a high-pass filter.
        // Here we use a lightweight approach: compute pixel luminance variance.
        return await Task.detached(priority: .utility) {
            Self.laplacianVariance(image)
        }.value
    }

    private static func laplacianVariance(_ cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return 0 }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Compute luminance array
        var luminance = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = Double(pixelData[offset])
                let g = Double(pixelData[offset + 1])
                let b = Double(pixelData[offset + 2])
                luminance[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Laplacian convolution (simplified 3x3)
        var variance: Double = 0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let lap = -4 * luminance[y * width + x]
                    + luminance[(y - 1) * width + x]
                    + luminance[(y + 1) * width + x]
                    + luminance[y * width + (x - 1)]
                    + luminance[y * width + (x + 1)]
                variance += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let raw = variance / Double(count)
        // Normalise: values typically range 0–10000; clamp to [0,1]
        return min(raw / 5000.0, 1.0)
    }

    // MARK: - Exposure

    private func measureExposure(_ image: CGImage) async -> Double {
        await Task.detached(priority: .utility) {
            Self.exposureScore(image)
        }.value
    }

    private static func exposureScore(_ cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum: Double = 0
        let total = width * height
        for i in stride(from: 0, to: total * 4, by: 4) {
            let r = Double(pixelData[i])
            let g = Double(pixelData[i + 1])
            let b = Double(pixelData[i + 2])
            sum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }

        let mean = sum / Double(total)
        // Ideal exposure: mean luminance around 0.45–0.55
        // Score = 1 - |mean - 0.5| * 2 → peaks at 0.5
        return max(0, 1.0 - abs(mean - 0.5) * 2.0)
    }

    // MARK: - Eye Openness (Vision Landmarks)

    private func measureEyeOpenness(_ image: CGImage) async -> Double {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { request, _ in
                guard let faces = request.results as? [VNFaceObservation], !faces.isEmpty else {
                    continuation.resume(returning: 1.0) // 顔なし → ペナルティなし
                    return
                }

                var earSum: Double = 0
                var faceCount = 0

                for face in faces {
                    guard let landmarks = face.landmarks else { continue }
                    let leftEAR = Self.eyeAspectRatio(landmarks.leftEye)
                    let rightEAR = Self.eyeAspectRatio(landmarks.rightEye)
                    if let l = leftEAR, let r = rightEAR {
                        earSum += Double((l + r) / 2)
                        faceCount += 1
                    }
                }

                guard faceCount > 0 else {
                    continuation.resume(returning: 1.0)
                    return
                }

                let avgEAR = earSum / Double(faceCount)
                // EAR: 0.0〜0.5程度。0.15以下で目つぶりと判定
                // 0–1 スコアに正規化（0.15=閉じ, 0.30=開き）
                let score = min(max((avgEAR - 0.15) / 0.15, 0.0), 1.0)
                continuation.resume(returning: score)
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    private static func eyeAspectRatio(_ eye: VNFaceLandmarkRegion2D?) -> Float? {
        guard let eye, eye.pointCount >= 6 else { return nil }
        let pts = eye.normalizedPoints
        // 縦方向の距離（上下2点ずつ）/ 横方向の距離
        let height1 = dist(pts[1], pts[5])
        let height2 = dist(pts[2], pts[4])
        let width   = dist(pts[0], pts[3])
        guard width > 0 else { return nil }
        return (height1 + height2) / (2.0 * width)
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> Float {
        let dx = Float(a.x - b.x)
        let dy = Float(a.y - b.y)
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Face Quality (Vision)

    private func measureFaceQuality(_ image: CGImage) async -> (Double, Bool) {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceCaptureQualityRequest { request, _ in
                guard let results = request.results as? [VNFaceObservation],
                      !results.isEmpty else {
                    continuation.resume(returning: (0.0, false))
                    return
                }
                // Average quality across all detected faces
                let total = results.compactMap { $0.faceCaptureQuality }.reduce(0, +)
                let avg = Double(total) / Double(results.count)
                continuation.resume(returning: (avg, true))
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }
}
