import Foundation
import UIKit
import CoreGraphics
import UltralyticsYOLO

enum HoldDetectorError: LocalizedError {
    case modelUnavailable
    case noMasks

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The on-device model is missing from this build. Please reinstall or update the app."
        case .noMasks:
            return "The model returned no climbing-hold masks for this image."
        }
    }
}

final class YOLOHoldDetector: @unchecked Sendable {
    private var model: YOLO?
    private(set) var loadError: String?

    func loadIfAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            self.model = YOLO(
                "ClimbHoldSeg",
                task: .segment,
                useGpu: true,
                numItemsThreshold: 500
            ) { result in
                switch result {
                case .success(let loaded):
                    loaded.setThresholds(
                        numItems: 500,
                        confidence: 0.15,
                        iou: 0.60
                    )
                    self.model = loaded
                    self.loadError = nil
                    continuation.resume(returning: true)

                case .failure(let error):
                    self.loadError = error.localizedDescription
                    self.model = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func setConfidence(_ confidence: Double) {
        model?.setConfidenceThreshold(confidence)
    }

    func detect(image: UIImage, confidence: Double) async throws -> AnalysisResult {
        guard let model, model.isLoaded else {
            throw HoldDetectorError.modelUnavailable
        }

        model.setThresholds(
            numItems: 500,
            confidence: confidence,
            iou: 0.60
        )

        let result = await Task.detached(priority: .userInitiated) {
            model(image)
        }.value

        guard let maskSet = result.masks?.masks, !maskSet.isEmpty else {
            throw HoldDetectorError.noMasks
        }

        let count = min(maskSet.count, result.boxes.count)
        var holds: [HoldInstance] = []
        holds.reserveCapacity(count)

        for index in 0..<count {
            let floatMask = maskSet[index]
            let box = result.boxes[index].xywhn
            guard let binary = Self.crop(
                floatMask: floatMask,
                normalizedBox: box
            ) else { continue }

            let srcH = floatMask.count
            let srcW = floatMask.first?.count ?? 0
            let contours = ContourBuilder.contours(
                field: floatMask,
                boxX0: Int(floor(box.minX * CGFloat(srcW))) - 1,
                boxY0: Int(floor(box.minY * CGFloat(srcH))) - 1,
                boxX1: Int(ceil(box.maxX * CGFloat(srcW))) + 1,
                boxY1: Int(ceil(box.maxY * CGFloat(srcH))) + 1,
                threshold: Self.logitThreshold
            )

            holds.append(
                HoldInstance(
                    id: index,
                    confidence: result.boxes[index].conf,
                    mask: binary,
                    contours: contours,
                    lab: nil
                )
            )
        }

        if holds.isEmpty {
            throw HoldDetectorError.noMasks
        }

        return AnalysisResult(
            holds: holds,
            inferenceMilliseconds: result.preMs + result.inferenceMs + result.postMs
        )
    }

    /// Per-instance masks from UltralyticsYOLO are raw prototype LOGITS
    /// (no sigmoid), already zeroed outside the detection box, at prototype
    /// resolution (e.g. 160×120 for a 4:3 photo). Ultralytics thresholds
    /// sigmoid > 0.5, which is logit > 0. v1.2 used `> 0.50` on the logits,
    /// i.e. sigmoid > 0.62, which shrank every mask and dropped small footholds.
    ///
    /// The mask is also bilinearly upsampled so overlays, saved results and
    /// tap hit-testing are not limited to the coarse prototype grid.
    static let maskUpsample = 4
    static let logitThreshold: Float = 0

    private static func crop(
        floatMask: [[Float]],
        normalizedBox: CGRect
    ) -> BinaryMask? {
        let srcH = floatMask.count
        guard srcH > 0 else { return nil }
        let srcW = floatMask[0].count
        guard srcW > 0, floatMask.allSatisfy({ $0.count == srcW }) else { return nil }

        let s = maskUpsample
        let canvasW = srcW * s
        let canvasH = srcH * s

        // Box in canvas pixels (masks are already zero outside the box, so no padding).
        let x0 = min(max(Int(floor(normalizedBox.minX * CGFloat(canvasW))), 0), canvasW - 1)
        let y0 = min(max(Int(floor(normalizedBox.minY * CGFloat(canvasH))), 0), canvasH - 1)
        let x1 = min(max(Int(ceil(normalizedBox.maxX * CGFloat(canvasW))), x0 + 1), canvasW)
        let y1 = min(max(Int(ceil(normalizedBox.maxY * CGFloat(canvasH))), y0 + 1), canvasH)

        let cropW = x1 - x0
        let cropH = y1 - y0
        guard cropW > 0, cropH > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: cropW * cropH)
        var onCount = 0
        let inv = 1.0 / Float(s)

        for cy in y0..<y1 {
            let v = (Float(cy) + 0.5) * inv - 0.5
            let vy0 = min(max(Int(floor(v)), 0), srcH - 1)
            let vy1 = min(vy0 + 1, srcH - 1)
            let fy = min(max(v - Float(vy0), 0), 1)
            let rowA = floatMask[vy0]
            let rowB = floatMask[vy1]

            for cx in x0..<x1 {
                let u = (Float(cx) + 0.5) * inv - 0.5
                let ux0 = min(max(Int(floor(u)), 0), srcW - 1)
                let ux1 = min(ux0 + 1, srcW - 1)
                let fx = min(max(u - Float(ux0), 0), 1)

                let top = rowA[ux0] + (rowA[ux1] - rowA[ux0]) * fx
                let bottom = rowB[ux0] + (rowB[ux1] - rowB[ux0]) * fx
                let value = top + (bottom - top) * fy

                if value > logitThreshold {
                    bytes[(cy - y0) * cropW + (cx - x0)] = 1
                    onCount += 1
                }
            }
        }

        guard onCount >= 6 * s * s else { return nil }

        return BinaryMask(
            canvasWidth: canvasW,
            canvasHeight: canvasH,
            x: x0,
            y: y0,
            width: cropW,
            height: cropH,
            pixels: bytes
        )
    }
}
