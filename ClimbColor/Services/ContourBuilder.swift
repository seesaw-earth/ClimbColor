import CoreGraphics

/// Turns a low-resolution mask *probability field* into smooth vector outlines.
///
/// The YOLO prototype masks are ~160 px across the whole photo. Thresholding
/// first and then scaling up gives the blocky "staircase" edges seen in v1/v2.
/// Instead we run marching squares directly on the float logits, placing each
/// boundary point at the sub-pixel position where the field crosses the
/// threshold, then smooth the polygon (Chaikin). The result is resolution-
/// independent and is drawn at native screen / photo resolution.
enum ContourBuilder {
    static func contours(
        field: [[Float]],
        boxX0: Int, boxY0: Int, boxX1: Int, boxY1: Int,
        threshold: Float = 0,
        smoothingPasses: Int = 2
    ) -> [[CGPoint]] {
        let srcH = field.count
        guard srcH > 0 else { return [] }
        let srcW = field[0].count
        guard srcW > 0 else { return [] }

        let bx0 = max(0, boxX0), by0 = max(0, boxY0)
        let bx1 = min(srcW, boxX1), by1 = min(srcH, boxY1)
        guard bx1 > bx0, by1 > by0 else { return [] }

        // Sample grid = box plus a one-sample "outside" border so every
        // contour closes.
        let ox = bx0 - 1, oy = by0 - 1
        let w = (bx1 - bx0) + 2
        let h = (by1 - by0) + 2
        let outside = threshold - 2

        var v = [Float](repeating: outside, count: w * h)
        for j in 1..<(h - 1) {
            let row = field[oy + j]
            for i in 1..<(w - 1) {
                let value = row[ox + i]
                // UltralyticsYOLO writes exact 0 outside the detection box.
                v[j * w + i] = value == 0 ? outside : value
            }
        }

        @inline(__always) func at(_ i: Int, _ j: Int) -> Float { v[j * w + i] }
        @inline(__always) func hEdge(_ i: Int, _ j: Int) -> Int { (j * w + i) * 2 }
        @inline(__always) func vEdge(_ i: Int, _ j: Int) -> Int { (j * w + i) * 2 + 1 }

        var adjacency: [Int: [Int]] = [:]
        func link(_ a: Int, _ b: Int) {
            adjacency[a, default: []].append(b)
            adjacency[b, default: []].append(a)
        }

        for j in 0..<(h - 1) {
            for i in 0..<(w - 1) {
                let tl = at(i, j), tr = at(i + 1, j)
                let br = at(i + 1, j + 1), bl = at(i, j + 1)
                var index = 0
                if tl > threshold { index |= 8 }
                if tr > threshold { index |= 4 }
                if br > threshold { index |= 2 }
                if bl > threshold { index |= 1 }
                if index == 0 || index == 15 { continue }

                let top = hEdge(i, j), bottom = hEdge(i, j + 1)
                let left = vEdge(i, j), right = vEdge(i + 1, j)
                let centerInside = (tl + tr + br + bl) / 4 > threshold

                switch index {
                case 1, 14: link(left, bottom)
                case 2, 13: link(bottom, right)
                case 3, 12: link(left, right)
                case 4, 11: link(top, right)
                case 6, 9: link(top, bottom)
                case 7, 8: link(left, top)
                case 5:
                    if centerInside { link(left, top); link(bottom, right) }
                    else { link(top, right); link(left, bottom) }
                case 10:
                    if centerInside { link(top, right); link(left, bottom) }
                    else { link(left, top); link(bottom, right) }
                default: break
                }
            }
        }

        func crossing(_ a: Float, _ b: Float) -> CGFloat {
            let d = b - a
            guard abs(d) > 1e-6 else { return 0.5 }
            return CGFloat(min(max((threshold - a) / d, 0), 1))
        }

        func point(for edge: Int) -> CGPoint {
            let base = edge / 2
            let i = base % w, j = base / w
            let gx: CGFloat, gy: CGFloat
            if edge % 2 == 0 {
                gx = CGFloat(i) + crossing(at(i, j), at(i + 1, j)); gy = CGFloat(j)
            } else {
                gx = CGFloat(i); gy = CGFloat(j) + crossing(at(i, j), at(i, j + 1))
            }
            // Sample (i, j) is the CENTER of source pixel (ox + i, oy + j).
            return CGPoint(
                x: (CGFloat(ox) + gx + 0.5) / CGFloat(srcW),
                y: (CGFloat(oy) + gy + 0.5) / CGFloat(srcH)
            )
        }

        var visited = Set<Int>()
        var loops: [[CGPoint]] = []

        for start in adjacency.keys where !visited.contains(start) {
            var chain = [start]
            visited.insert(start)
            var current = start
            while let next = adjacency[current]?.first(where: { !visited.contains($0) }) {
                visited.insert(next)
                chain.append(next)
                current = next
            }
            guard chain.count >= 3 else { continue }

            var polygon = chain.map(point(for:))
            // Drop specks smaller than ~1 source pixel.
            let pixelArea = abs(signedArea(polygon)) * CGFloat(srcW * srcH)
            guard pixelArea >= 1.0 else { continue }

            for _ in 0..<smoothingPasses { polygon = chaikin(polygon) }
            loops.append(polygon)
        }

        return loops
    }

    static func signedArea(_ p: [CGPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for k in 0..<p.count {
            let a = p[k], b = p[(k + 1) % p.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Corner-cutting smoothing for a closed polygon.
    static func chaikin(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count >= 3 else { return p }
        var out: [CGPoint] = []
        out.reserveCapacity(p.count * 2)
        for k in 0..<p.count {
            let a = p[k], b = p[(k + 1) % p.count]
            out.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
            out.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
        }
        return out
    }

    /// Unit-space path (x, y in 0...1). Even-odd fill handles holes.
    static func path(for contours: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for loop in contours where loop.count >= 3 {
            path.addLines(between: loop)
            path.closeSubpath()
        }
        return path
    }
}
