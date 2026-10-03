import CoreGraphics
import Foundation

/// Builds holds the user adds with a long-press.
enum ManualHoldFactory {
    /// Mask grid for hand-added holds: the photo at ≤ 2048 px long side, so
    /// small footholds keep a usable mask.
    static func canvasSize(for pixelSize: CGSize) -> (width: Int, height: Int) {
        let longest = max(pixelSize.width, pixelSize.height, 1)
        let k = min(1, 2048 / longest)
        return (max(1, Int((pixelSize.width * k).rounded())),
                max(1, Int((pixelSize.height * k).rounded())))
    }

    /// A circle of `radiusPixels` (photo pixels) around a normalized point.
    static func circle(id: Int, center: CGPoint, radiusPixels: CGFloat, pixelSize: CGSize) -> HoldInstance? {
        guard pixelSize.width > 0, pixelSize.height > 0, radiusPixels > 0 else { return nil }
        let canvas = canvasSize(for: pixelSize)
        let cw = CGFloat(canvas.width)
        let ch = CGFloat(canvas.height)
        let rx = max(1, radiusPixels / pixelSize.width * cw)
        let ry = max(1, radiusPixels / pixelSize.height * ch)
        let cx = center.x * cw
        let cy = center.y * ch

        let x0 = max(0, Int(floor(cx - rx)))
        let x1 = min(canvas.width, Int(ceil(cx + rx)) + 1)
        let y0 = max(0, Int(floor(cy - ry)))
        let y1 = min(canvas.height, Int(ceil(cy + ry)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }

        let width = x1 - x0
        var pixels = [UInt8](repeating: 0, count: width * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = (CGFloat(x) + 0.5 - cx) / rx
                let dy = (CGFloat(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1 {
                    pixels[(y - y0) * width + (x - x0)] = 1
                }
            }
        }
        let mask = BinaryMask(canvasWidth: canvas.width, canvasHeight: canvas.height,
                              x: x0, y: y0, width: width, height: y1 - y0, pixels: pixels)

        var loop: [CGPoint] = []
        let steps = 48
        for k in 0..<steps {
            let t = Double(k) / Double(steps) * 2 * Double.pi
            loop.append(CGPoint(x: center.x + radiusPixels * CGFloat(cos(t)) / pixelSize.width,
                                y: center.y + radiusPixels * CGFloat(sin(t)) / pixelSize.height))
        }
        return HoldInstance(id: id, confidence: 1, mask: mask, contours: [loop],
                            lab: nil, isManual: true)
    }

    /// Re-maps a hold found by running the model on a crop back into
    /// whole-photo coordinates. `cropRect` is normalized to the photo.
    static func remap(_ cropHold: HoldInstance, id: Int, cropRect: CGRect,
                      pixelSize: CGSize, lab: LabColor?) -> HoldInstance? {
        let canvas = canvasSize(for: pixelSize)
        let cw = CGFloat(canvas.width)
        let ch = CGFloat(canvas.height)
        let b = cropHold.normalizedBounds

        let gx0 = max(0, Int(floor((cropRect.minX + b.minX * cropRect.width) * cw)))
        let gx1 = min(canvas.width, Int(ceil((cropRect.minX + b.maxX * cropRect.width) * cw)))
        let gy0 = max(0, Int(floor((cropRect.minY + b.minY * cropRect.height) * ch)))
        let gy1 = min(canvas.height, Int(ceil((cropRect.minY + b.maxY * cropRect.height) * ch)))
        guard gx1 > gx0, gy1 > gy0, cropRect.width > 0, cropRect.height > 0 else { return nil }

        let width = gx1 - gx0
        var pixels = [UInt8](repeating: 0, count: width * (gy1 - gy0))
        var onCount = 0
        for gy in gy0..<gy1 {
            let py = (CGFloat(gy) + 0.5) / ch
            let qy = (py - cropRect.minY) / cropRect.height
            for gx in gx0..<gx1 {
                let px = (CGFloat(gx) + 0.5) / cw
                let qx = (px - cropRect.minX) / cropRect.width
                if cropHold.mask.contains(normalized: CGPoint(x: qx, y: qy)) {
                    pixels[(gy - gy0) * width + (gx - gx0)] = 1
                    onCount += 1
                }
            }
        }
        guard onCount > 0 else { return nil }

        var loops: [[CGPoint]] = []
        for loop in cropHold.contours {
            var mapped: [CGPoint] = []
            mapped.reserveCapacity(loop.count)
            for q in loop {
                mapped.append(CGPoint(x: cropRect.minX + q.x * cropRect.width,
                                      y: cropRect.minY + q.y * cropRect.height))
            }
            loops.append(mapped)
        }

        let mask = BinaryMask(canvasWidth: canvas.width, canvasHeight: canvas.height,
                              x: gx0, y: gy0, width: width, height: gy1 - gy0, pixels: pixels)
        return HoldInstance(id: id, confidence: cropHold.confidence, mask: mask,
                            contours: loops, lab: lab, isManual: true)
    }
}
