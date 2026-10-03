import Foundation
import ImageIO
import UIKit

/// Session photos live as ORIGINAL files on disk (never re-encoded or
/// cropped). Images are decoded on demand at whatever size is needed:
/// full resolution for the photo on screen, small copies for analysis
/// and thumbnails. This keeps memory flat even with dozens of 48 MP photos.
enum PhotoFiles {
    static var sessionDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClimbColorSession", isDirectory: true)
    }

    static func clearSession() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func newURL(ext: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: sessionDirectory, withIntermediateDirectories: true)
        return sessionDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Copies a file the system hands us (it is deleted when the callback ends).
    static func importCopy(of source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let destination = try newURL(ext: ext)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func store(_ data: Data, ext: String) throws -> URL {
        let destination = try newURL(ext: ext)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Upright pixel size (EXIF orientation applied).
    static func pixelSize(of url: URL) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = raw[kCGImagePropertyPixelWidth as String] as? Int,
            let height = raw[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0
        else { return nil }

        let orientation: Int = (raw[kCGImagePropertyOrientation as String] as? Int) ?? 1
        // EXIF orientations 5...8 are rotated 90 degrees.
        if orientation >= 5 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// Upright image whose longest side is at most `maxPixel`
    /// (`nil` = full original resolution).
    static func image(at url: URL, maxPixel: Int?) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let size = pixelSize(of: url)
        else { return nil }

        let longest = Int(max(size.width, size.height))
        let limit = min(maxPixel ?? longest, longest)
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceShouldCacheImmediately as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: limit
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
