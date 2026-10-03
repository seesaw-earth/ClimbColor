import CoreGraphics
import UIKit

struct RGBPixel: Sendable {
    let r: Double
    let g: Double
    let b: Double
}

struct ImagePixelBuffer: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(image: UIImage, maxDimension: Int) {
        guard let cgImage = image.normalizedCGImage() else { return nil }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1.0, Double(maxDimension) / Double(max(sourceWidth, sourceHeight)))
        let targetWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))
        var data = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)

        guard let context = CGContext(
            data: &data,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // Drawing a CGImage straight into a bitmap context already places the
        // image's top row at byte 0. Do NOT flip the CTM here: a flip stores the
        // image upside-down and every color sample would come from the
        // vertically mirrored position (v1.2 bug).
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        self.width = targetWidth
        self.height = targetHeight
        self.bytes = data
    }

    func pixel(normalizedX: Double, normalizedY: Double) -> RGBPixel? {
        guard width > 0, height > 0 else { return nil }
        let x = min(max(Int(normalizedX * Double(width)), 0), width - 1)
        let y = min(max(Int(normalizedY * Double(height)), 0), height - 1)
        let index = (y * width + x) * 4
        guard index + 2 < bytes.count else { return nil }
        return RGBPixel(
            r: Double(bytes[index]) / 255.0,
            g: Double(bytes[index + 1]) / 255.0,
            b: Double(bytes[index + 2]) / 255.0
        )
    }
}

extension UIImage {
    func normalizedForProcessing() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Upright (`.up`), scale-1 copy whose longest side is at most
    /// `maxDimension` pixels. Keeps 48 MP imports from exhausting memory when
    /// the result is composited and saved.
    func preparedForAnalysis(maxDimension: CGFloat = 4032) -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return self }

        let factor = min(1, maxDimension / longest)
        if factor >= 1, imageOrientation == .up, scale == 1 { return self }

        let target = CGSize(
            width: (pixelSize.width * factor).rounded(),
            height: (pixelSize.height * factor).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func normalizedCGImage() -> CGImage? {
        normalizedForProcessing().cgImage
    }
}
