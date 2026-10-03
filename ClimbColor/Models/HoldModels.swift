import CoreGraphics
import Foundation

struct LabColor: Sendable, Equatable {
    let l: Double
    let a: Double
    let b: Double
}

struct BinaryMask: Sendable, Equatable {
    let canvasWidth: Int
    let canvasHeight: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let pixels: [UInt8]

    var normalizedBounds: CGRect {
        CGRect(
            x: CGFloat(x) / CGFloat(max(canvasWidth, 1)),
            y: CGFloat(y) / CGFloat(max(canvasHeight, 1)),
            width: CGFloat(width) / CGFloat(max(canvasWidth, 1)),
            height: CGFloat(height) / CGFloat(max(canvasHeight, 1))
        )
    }

    var pixelCount: Int {
        pixels.reduce(into: 0) { $0 += $1 > 0 ? 1 : 0 }
    }

    func contains(normalized point: CGPoint) -> Bool {
        guard canvasWidth > 0, canvasHeight > 0,
              (0...1).contains(point.x), (0...1).contains(point.y)
        else { return false }

        let gx = min(max(Int(point.x * CGFloat(canvasWidth)), 0), canvasWidth - 1)
        let gy = min(max(Int(point.y * CGFloat(canvasHeight)), 0), canvasHeight - 1)
        guard gx >= x, gy >= y, gx < x + width, gy < y + height else { return false }

        let localX = gx - x
        let localY = gy - y
        let index = localY * width + localX
        return index >= 0 && index < pixels.count && pixels[index] > 0
    }

    func forEachOnPixel(step: Int = 1, _ body: (Int, Int) -> Void) {
        let safeStep = max(1, step)
        guard width > 0, height > 0 else { return }

        var row = 0
        while row < height {
            var col = 0
            while col < width {
                if pixels[row * width + col] > 0 {
                    body(x + col, y + row)
                }
                col += safeStep
            }
            row += safeStep
        }
    }
}

struct HoldInstance: Identifiable, Sendable, Equatable {
    let id: Int
    let confidence: Float
    let mask: BinaryMask
    /// Smooth closed outlines in normalized (0...1) image coordinates,
    /// extracted from the model's probability field (sub-pixel, not blocky).
    let contours: [[CGPoint]]
    var lab: LabColor?
    /// Added by the user with a long-press (circle or re-detected outline).
    var isManual = false

    var normalizedBounds: CGRect { mask.normalizedBounds }

    /// Tight bounds of the drawn outline (normalized), for placing labels.
    var outlineBounds: CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for loop in contours {
            for p in loop {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return normalizedBounds }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// How the holds of a route are labeled, chosen on the home screen.
enum HoldLabelStyle: String, CaseIterable, Identifiable, Sendable {
    case numbers, letters, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbers: return "1 2 3"
        case .letters: return "A B C"
        case .off: return "Off"
        }
    }

    /// 0 → "1" / "A", 25 → "26" / "Z", 26 → "27" / "AA" …
    func label(for index: Int) -> String {
        switch self {
        case .numbers:
            return "\(index + 1)"
        case .letters:
            var n = index
            var text = ""
            repeat {
                let scalar = UnicodeScalar(UInt8(65 + n % 26))
                text = String(Character(scalar)) + text
                n = n / 26 - 1
            } while n >= 0
            return text
        case .off:
            return ""
        }
    }

    /// Labels for the route holds, in climbing order: lowest on the wall
    /// first (bottom → top); holds at the same height go left → right.
    static func labels(routeIDs: Set<Int>, holds: [HoldInstance], style: HoldLabelStyle) -> [Int: String] {
        guard style != .off, !routeIDs.isEmpty else { return [:] }
        var members: [(id: Int, band: Int, x: CGFloat)] = []
        for hold in holds where routeIDs.contains(hold.id) {
            let b = hold.outlineBounds
            // Height bands of 1.5% of the photo: holds at about the same
            // height are ordered left → right.
            let band = Int((b.midY / 0.015).rounded())
            members.append((id: hold.id, band: band, x: b.midX))
        }
        members.sort { a, b in
            if a.band != b.band { return a.band > b.band }   // larger y = lower on the photo
            return a.x < b.x
        }
        var result: [Int: String] = [:]
        for (index, member) in members.enumerated() {
            result[member.id] = style.label(for: index)
        }
        return result
    }
}

/// Holds the algorithm thinks share one color, shown as a button.
struct ColorCluster: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String          // "Purple", "Light Blue" … (readable even when colors aren't)
    let lab: LabColor         // average color
    let holdIDs: [Int]        // largest hold first

    var count: Int { holdIDs.count }
}

/// How a hold is drawn. Outline-first so the hold's real color stays visible.
enum HoldRole: Int, Comparable {
    case dimmed = 0, idle, route, selected

    static func < (lhs: HoldRole, rhs: HoldRole) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `selectedID` is the hold the user tapped (nil when the route was
    /// chosen with a color button); `routeIDs` is the whole route.
    static func of(id: Int, selectedID: Int?, routeIDs: Set<Int>) -> HoldRole {
        if routeIDs.isEmpty { return .idle }
        if let selectedID, id == selectedID { return .selected }
        return routeIDs.contains(id) ? .route : .dimmed
    }
}

struct AnalysisResult: Sendable {
    var holds: [HoldInstance]
    let inferenceMilliseconds: Double?
}

struct SavedAnalysis: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let imageFilename: String
    let detectedCount: Int
    let matchedCount: Int?
    let kind: String

    var subtitle: String {
        if let matchedCount {
            return "\(matchedCount) same-color holds • \(detectedCount) detected"
        }
        return "\(detectedCount) holds detected"
    }
}
