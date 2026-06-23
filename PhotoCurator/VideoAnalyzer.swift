import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - BestShotCandidate

struct BestShotCandidate: Identifiable {
    let id = UUID()
    let time: CMTime
    let timeSeconds: Double
    let score: Double
    let thumbnail: UIImage
}

// MARK: - VideoAnalyzer

actor VideoAnalyzer {
    static let shared = VideoAnalyzer()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public

    /// 動画からベストショット候補を返す（時刻昇順）
    func findBestShots(asset: AVAsset, count: Int = 5) async -> [BestShotCandidate] {
        let duration: Double
        do { duration = try await asset.load(.duration).seconds }
        catch { return [] }
        guard duration > 0 else { return [] }

        // 動画長に応じてサンプル間隔を調整
        let interval: Double = duration > 120 ? 2.0 : duration > 30 ? 1.0 : 0.5

        var times: [CMTime] = []
        var t = max(0.3, interval * 0.4)
        while t < duration - 0.2 {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }
        guard !times.isEmpty else { return [] }

        // スコアリング用に縮小フレームを生成
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval * 0.45, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: interval * 0.45, preferredTimescale: 600)

        var candidates: [BestShotCandidate] = []

        for time in times {
            guard let (cg, _) = try? await generator.image(at: time) else { continue }

            let sharpness  = scoreSharpness(cg)
            let brightness = scoreBrightness(cg)
            let faceScore  = await scoreFaces(cg)
            let hasFace    = faceScore > 0.01

            let total = hasFace
                ? sharpness * 0.50 + faceScore * 0.30 + brightness * 0.20
                : sharpness * 0.70 + brightness * 0.30

            candidates.append(BestShotCandidate(
                time: time,
                timeSeconds: time.seconds,
                score: total,
                thumbnail: UIImage(cgImage: cg)
            ))
        }

        // スコア降順 → 近い時刻(< 1.5s)は除外 → 上位 count 件
        let sorted = candidates.sorted { $0.score > $1.score }
        var result: [BestShotCandidate] = []
        for c in sorted {
            guard !result.contains(where: { abs($0.timeSeconds - c.timeSeconds) < 1.5 }) else { continue }
            result.append(c)
            if result.count >= count { break }
        }

        return result.sorted { $0.timeSeconds < $1.timeSeconds }
    }

    // MARK: - Sharpness (Laplacian エッジ強度)

    private func scoreSharpness(_ cg: CGImage) -> Double {
        let ci    = CIImage(cgImage: cg)
        let scale = min(1.0, 320.0 / Double(cg.width))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let edge = CIFilter.edges()
        edge.inputImage = small
        edge.intensity  = 1.0
        guard let edgeOut = edge.outputImage else { return 0.5 }

        let avg = CIFilter.areaAverage()
        avg.inputImage = edgeOut
        avg.extent     = edgeOut.extent
        guard let avgOut = avg.outputImage else { return 0.5 }

        var px = [Float](repeating: 0, count: 4)
        ciContext.render(avgOut, toBitmap: &px, rowBytes: 16,
                         bounds: CGRect(origin: avgOut.extent.origin, size: CGSize(width: 1, height: 1)),
                         format: .RGBAf, colorSpace: nil)

        return min(1.0, Double(px[0]) * 6.0)
    }

    // MARK: - Brightness (適正露出)

    private func scoreBrightness(_ cg: CGImage) -> Double {
        let ci  = CIImage(cgImage: cg)
        let avg = CIFilter.areaAverage()
        avg.inputImage = ci
        avg.extent     = ci.extent
        guard let out = avg.outputImage else { return 0.5 }

        var px = [Float](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 16,
                         bounds: CGRect(origin: out.extent.origin, size: CGSize(width: 1, height: 1)),
                         format: .RGBAf, colorSpace: nil)

        let luma = 0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])
        return max(0, 1.0 - abs(luma - 0.45) * 2.8)
    }

    // MARK: - Face Quality (VNDetectFaceCaptureQualityRequest)

    private func scoreFaces(_ cg: CGImage) async -> Double {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req     = VNDetectFaceCaptureQualityRequest()
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([req])
                    let best = (req.results ?? [])
                        .compactMap { $0.faceCaptureQuality }
                        .max().map(Double.init) ?? 0.0
                    cont.resume(returning: best)
                } catch {
                    cont.resume(returning: 0.0)
                }
            }
        }
    }
}
