import CryptoKit
import Foundation
import ImageIO
import UIKit

// MARK: - Stored formats
//
// Documents/ClimbColorLibrary/
//   index.json                 every wall: dates, place, route, counts
//   photos/<id>.<heic|jpg>     the ORIGINAL file, byte-for-byte
//   thumbs/<id>.jpg            small preview for the library
//   analyses/<id>.json         detection result (holds, masks, outlines, colors)
//
// All of it is plain JSON so it can be inspected, exported or migrated later.

/// The route the user picked on a wall, so it reopens exactly as they left it.
struct RouteState: Codable, Equatable, Sendable {
    var selectedID: Int
    var addedIDs: [Int]
    var removedIDs: [Int]
    var tolerance: Double
    var colorHex: String?
    var holdCount: Int
    /// Readable color name, e.g. "Purple". Optional for older files.
    var colorName: String?
    /// false when chosen with a color button (no single tapped hold).
    var anchorVisible: Bool?
}

/// A route the climber completed ("sent") on a wall.
struct SendRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let colorName: String
    let colorHex: String?
    /// The exact holds of the route, so it can be shown again later.
    let holdIDs: [Int]
}

/// One wall photo in the library.
struct WallRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    /// SHA-256 of the original file: re-importing the same photo reuses this record.
    let contentHash: String
    let pixelWidth: Int
    let pixelHeight: Int
    let importedAt: Date
    var capturedAt: Date?
    var latitude: Double?
    var longitude: Double?
    /// Found automatically from the photo's GPS (nearest climbing gym / area).
    var placeName: String?
    /// The user's own name for the place. Always wins over `placeName`.
    var customPlaceName: String?
    var holdCount: Int?
    var analyzedAt: Date?
    var analysisConfidence: Double?
    var route: RouteState?
    /// Completed routes on this wall. Optional so older libraries still load.
    var sends: [SendRecord]?

    var date: Date { capturedAt ?? importedAt }
    var sendCount: Int { sends?.count ?? 0 }
    var displayPlace: String? { customPlaceName ?? placeName }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}

/// Detection result for one photo (`analyses/<id>.json`).
struct AnalysisFile: Codable, Sendable {
    var version: Int = 1
    var model: String = "ClimbHoldSeg"
    var confidence: Double
    var createdAt: Date
    var holds: [HoldRecord]
}

struct MaskRecord: Codable, Sendable {
    let canvasWidth: Int
    let canvasHeight: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// 1 bit per pixel of the cropped mask, row-major.
    let bits: Data

    static func pack(_ pixels: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: (pixels.count + 7) / 8)
        for i in 0..<pixels.count where pixels[i] > 0 {
            bytes[i >> 3] |= UInt8(1 << (i & 7))
        }
        return Data(bytes)
    }

    static func unpack(_ data: Data, count: Int) -> [UInt8] {
        let bytes = [UInt8](data)
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let byteIndex = i >> 3
            if byteIndex < bytes.count, bytes[byteIndex] & UInt8(1 << (i & 7)) != 0 {
                out[i] = 1
            }
        }
        return out
    }
}

struct HoldRecord: Codable, Sendable {
    let id: Int
    let confidence: Float
    /// CIELAB [L, a, b]
    let lab: [Double]?
    let mask: MaskRecord
    /// Each outline loop flattened as x0, y0, x1, y1, … in normalized 0…1 coordinates.
    let contours: [[Float]]
    /// true = added by the user (long-press). Optional so older files still load.
    let manual: Bool?

    init(hold: HoldInstance) {
        id = hold.id
        manual = hold.isManual ? true : nil
        confidence = hold.confidence
        if let color = hold.lab {
            lab = [color.l, color.a, color.b]
        } else {
            lab = nil
        }
        let m = hold.mask
        mask = MaskRecord(canvasWidth: m.canvasWidth, canvasHeight: m.canvasHeight,
                          x: m.x, y: m.y, width: m.width, height: m.height,
                          bits: MaskRecord.pack(m.pixels))
        var loops: [[Float]] = []
        for loop in hold.contours {
            var flat: [Float] = []
            flat.reserveCapacity(loop.count * 2)
            for point in loop {
                flat.append(Float(point.x))
                flat.append(Float(point.y))
            }
            loops.append(flat)
        }
        contours = loops
    }

    func instance() -> HoldInstance? {
        let count = mask.width * mask.height
        guard count > 0 else { return nil }
        let binary = BinaryMask(
            canvasWidth: mask.canvasWidth, canvasHeight: mask.canvasHeight,
            x: mask.x, y: mask.y, width: mask.width, height: mask.height,
            pixels: MaskRecord.unpack(mask.bits, count: count))

        var loops: [[CGPoint]] = []
        for flat in contours {
            var loop: [CGPoint] = []
            loop.reserveCapacity(flat.count / 2)
            var i = 0
            while i + 1 < flat.count {
                loop.append(CGPoint(x: CGFloat(flat[i]), y: CGFloat(flat[i + 1])))
                i += 2
            }
            loops.append(loop)
        }

        var color: LabColor?
        if let lab, lab.count == 3 {
            color = LabColor(l: lab[0], a: lab[1], b: lab[2])
        }
        return HoldInstance(id: id, confidence: confidence, mask: binary,
                            contours: loops, lab: color, isManual: manual ?? false)
    }
}

// MARK: - Library

final class WallLibrary: @unchecked Sendable {
    static let shared = WallLibrary()

    struct IngestOutcome: Sendable {
        var added: [WallRecord] = []
        var reused: [WallRecord] = []
        var failed = 0
    }

    let root: URL
    private let photosDir: URL
    private let thumbsDir: URL
    private let analysesDir: URL
    private let indexURL: URL
    private let thumbCache = NSCache<NSString, UIImage>()
    /// All index writes go through one serial queue, so they never race.
    private let ioQueue = DispatchQueue(label: "ClimbColor.library.io")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("ClimbColorLibrary", isDirectory: true)
        photosDir = root.appendingPathComponent("photos", isDirectory: true)
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        analysesDir = root.appendingPathComponent("analyses", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        for dir in [photosDir, thumbsDir, analysesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Paths

    func photoURL(for record: WallRecord) -> URL {
        photosDir.appendingPathComponent(record.fileName)
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func analysisURL(for id: UUID) -> URL {
        analysesDir.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Index

    private static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadIndex() -> [WallRecord] {
        guard
            let data = try? Data(contentsOf: indexURL),
            let records = try? Self.makeDecoder().decode([WallRecord].self, from: data)
        else { return [] }
        return records
    }

    func saveIndexAsync(_ records: [WallRecord]) {
        let url = indexURL
        ioQueue.async {
            if let data = try? Self.makeEncoder(pretty: true).encode(records) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Analyses

    func saveAnalysisAsync(_ file: AnalysisFile, for id: UUID) {
        let url = analysisURL(for: id)
        ioQueue.async {
            if let data = try? Self.makeEncoder(pretty: false).encode(file) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func loadAnalysis(for id: UUID) -> AnalysisFile? {
        guard let data = try? Data(contentsOf: analysisURL(for: id)) else { return nil }
        return try? Self.makeDecoder().decode(AnalysisFile.self, from: data)
    }

    // MARK: Thumbnails

    func thumbnail(for id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: thumbnailURL(for: id).path) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Import

    /// Moves freshly picked files into the library. Photos already in the
    /// library (same bytes) are not duplicated; their record is returned in
    /// `reused` so the saved analysis can be opened instantly.
    func ingest(files: [URL], known: [WallRecord],
                latitude: Double?, longitude: Double?, captureDate: Date?) -> IngestOutcome {
        var byHash: [String: WallRecord] = [:]
        for record in known { byHash[record.contentHash] = record }
        var outcome = IngestOutcome()

        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }

            guard let hash = Self.contentHash(of: file) else {
                outcome.failed += 1
                continue
            }
            if let existing = byHash[hash] {
                let alreadyListed = outcome.reused.contains { $0.id == existing.id }
                    || outcome.added.contains { $0.id == existing.id }
                if !alreadyListed { outcome.reused.append(existing) }
                continue
            }
            guard let size = PhotoFiles.pixelSize(of: file) else {
                outcome.failed += 1
                continue
            }

            let id = UUID()
            let ext = file.pathExtension.isEmpty ? "jpg" : file.pathExtension.lowercased()
            let fileName = "\(id.uuidString).\(ext)"
            let destination = photosDir.appendingPathComponent(fileName)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
            } catch {
                outcome.failed += 1
                continue
            }

            if let thumb = PhotoFiles.image(at: destination, maxPixel: 360),
               let data = thumb.jpegData(compressionQuality: 0.8) {
                try? data.write(to: thumbnailURL(for: id), options: .atomic)
            }

            let meta = Self.metadata(of: destination)
            let record = WallRecord(
                id: id, fileName: fileName, contentHash: hash,
                pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                importedAt: Date(),
                capturedAt: meta.date ?? captureDate,
                latitude: meta.latitude ?? latitude,
                longitude: meta.longitude ?? longitude)
            byHash[hash] = record
            outcome.added.append(record)
        }
        return outcome
    }

    func delete(_ record: WallRecord) {
        let urls = [photoURL(for: record), thumbnailURL(for: record.id), analysisURL(for: record.id)]
        thumbCache.removeObject(forKey: record.id.uuidString as NSString)
        ioQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: File facts

    static func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Capture time and GPS position from the photo's own EXIF data.
    static func metadata(of url: URL) -> (date: Date?, latitude: Double?, longitude: Double?) {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return (nil, nil, nil) }

        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            date = parseExifDate(raw, offset: offset)
        }

        var latitude: Double?
        var longitude: Double?
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef: String = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) ?? "N"
            let lonRef: String = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) ?? "E"
            latitude = latRef == "S" ? -lat : lat
            longitude = lonRef == "W" ? -lon : lon
        }
        return (date, latitude, longitude)
    }

    private static func parseExifDate(_ raw: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: raw + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }
}

// MARK: - Organizing: sessions and gyms

/// A visit: photos taken at the same place within a few hours.
struct WallSession: Identifiable {
    let id: String
    let place: String?
    let start: Date
    let records: [WallRecord]      // in the order they were taken

    var routeCount: Int { records.filter { $0.route != nil }.count }
    var sendCount: Int { records.reduce(0) { $0 + $1.sendCount } }
}

struct GymSummary: Identifiable {
    let name: String
    let records: [WallRecord]
    let sessionCount: Int
    let lastVisit: Date
    var id: String { name }
}

enum LibraryOrganizer {
    static let unknownPlace = "Unknown place"
    /// A gap longer than this starts a new session.
    static let sessionGap: TimeInterval = 4 * 3600

    static func sessions(_ records: [WallRecord]) -> [WallSession] {
        let sorted = records.sorted { $0.date < $1.date }
        var groups: [[WallRecord]] = []
        for record in sorted {
            if var last = groups.last, let previous = last.last, belongTogether(previous, record) {
                last.append(record)
                groups[groups.count - 1] = last
            } else {
                groups.append([record])
            }
        }
        var result: [WallSession] = []
        for group in groups.reversed() {
            guard let first = group.first else { continue }
            let place: String? = group.compactMap { $0.displayPlace }.first
            result.append(WallSession(id: first.id.uuidString, place: place,
                                      start: first.date, records: group))
        }
        return result
    }

    static func belongTogether(_ a: WallRecord, _ b: WallRecord) -> Bool {
        guard b.date.timeIntervalSince(a.date) < sessionGap else { return false }
        if let placeA = a.displayPlace, let placeB = b.displayPlace {
            return placeA == placeB
        }
        if let latA = a.latitude, let lonA = a.longitude,
           let latB = b.latitude, let lonB = b.longitude {
            return PlaceResolver.distance(latA, lonA, latB, lonB) < 1000
        }
        // One of them has no location (e.g. a screenshot): keep it with its neighbours.
        return true
    }

    static func gyms(_ records: [WallRecord]) -> [GymSummary] {
        var byPlace: [String: [WallRecord]] = [:]
        for session in sessions(records) {
            let name = session.place ?? unknownPlace
            byPlace[name, default: []].append(contentsOf: session.records)
        }
        var result: [GymSummary] = []
        for (name, group) in byPlace {
            let last: Date = group.map { $0.date }.max() ?? Date.distantPast
            let count = sessions(group).count
            result.append(GymSummary(name: name, records: group, sessionCount: count, lastVisit: last))
        }
        return result.sorted { $0.lastVisit > $1.lastVisit }
    }
}
