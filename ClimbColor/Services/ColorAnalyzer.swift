import Foundation
import UIKit

struct ColorAnalyzer: Sendable {
    func attachColors(to holds: [HoldInstance], image: UIImage) -> [HoldInstance] {
        guard let pixelBuffer = ImagePixelBuffer(image: image, maxDimension: 1100) else {
            return holds
        }

        return holds.map { hold in
            var updated = hold
            updated.lab = dominantLab(for: hold.mask, pixels: pixelBuffer)
            return updated
        }
    }

    func sameColorIDs(
        holds: [HoldInstance],
        selectedID: Int?,
        tolerance: Double
    ) -> Set<Int> {
        guard
            let selectedID,
            let selected = holds.first(where: { $0.id == selectedID }),
            let reference = selected.lab
        else { return [] }

        return Set(
            holds.compactMap { hold in
                guard let color = hold.lab else { return nil }
                return deltaE2000(reference, color) <= tolerance ? hold.id : nil
            }
        )
    }

    private func dominantLab(
        for mask: BinaryMask,
        pixels: ImagePixelBuffer
    ) -> LabColor? {
        var samples: [LabColor] = []
        var nonSpecular: [LabColor] = []
        let area = max(mask.pixelCount, 1)
        let step = max(1, Int(sqrt(Double(area) / 1500.0)))

        mask.forEachOnPixel(step: step) { gx, gy in
            let nx = (Double(gx) + 0.5) / Double(max(mask.canvasWidth, 1))
            let ny = (Double(gy) + 0.5) / Double(max(mask.canvasHeight, 1))

            guard let rgb = pixels.pixel(normalizedX: nx, normalizedY: ny) else {
                return
            }

            let maxRGB = max(rgb.r, max(rgb.g, rgb.b))
            let minRGB = min(rgb.r, min(rgb.g, rgb.b))
            guard maxRGB > 0.015 else { return }

            let saturation = maxRGB <= 0.0001
                ? 0
                : (maxRGB - minRGB) / maxRGB

            let lab = Self.rgbToLab(rgb)
            let chroma = hypot(lab.a, lab.b)

            samples.append(lab)

            // Very bright, achromatic pixels are usually glare/chalk on a
            // colored hold. v1.2 dropped them unconditionally (and dropped any
            // pixel at 255), so over-exposed WHITE holds ended up with no color
            // at all. Now they are only discarded if they are a minority.
            if !(lab.l > 97 && chroma < 4 && saturation < 0.03) {
                nonSpecular.append(lab)
            }
        }

        guard samples.count >= 3 else { return nil }

        if nonSpecular.count >= max(3, samples.count / 4) {
            samples = nonSpecular
        }

        let chromatic = samples.filter { hypot($0.a, $0.b) >= 16 }
        let chosen: [LabColor]

        // If the hold is clearly colored, use chromatic pixels to reduce
        // contamination from chalk and glare. Otherwise retain the neutral
        // samples so white, gray, and black holds still work.
        if chromatic.count >= max(8, samples.count / 3) {
            chosen = chromatic
        } else {
            chosen = samples
        }

        return LabColor(
            l: median(chosen.map(\.l)),
            a: median(chosen.map(\.a)),
            b: median(chosen.map(\.b))
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }

        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func rgbToLab(_ rgb: RGBPixel) -> LabColor {
        func linearize(_ c: Double) -> Double {
            c <= 0.04045
                ? c / 12.92
                : pow((c + 0.055) / 1.055, 2.4)
        }

        let r = linearize(rgb.r)
        let g = linearize(rgb.g)
        let b = linearize(rgb.b)

        let x = (
            0.4124564 * r +
            0.3575761 * g +
            0.1804375 * b
        ) / 0.95047

        let y = (
            0.2126729 * r +
            0.7151522 * g +
            0.0721750 * b
        )

        let z = (
            0.0193339 * r +
            0.1191920 * g +
            0.9503041 * b
        ) / 1.08883

        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > pow(delta, 3)
                ? pow(t, 1.0 / 3.0)
                : t / (3 * delta * delta) + 4.0 / 29.0
        }

        let fx = f(x)
        let fy = f(y)
        let fz = f(z)

        return LabColor(
            l: 116 * fy - 16,
            a: 500 * (fx - fy),
            b: 200 * (fy - fz)
        )
    }

    // MARK: Color groups (the color buttons)

    /// Groups holds by color. Large holds seed the groups (their color is
    /// measured most reliably), then every hold is re-assigned to the
    /// nearest group once.
    func clusters(for holds: [HoldInstance], threshold: Double = 12) -> [ColorCluster] {
        var items: [(id: Int, lab: LabColor, area: Int)] = []
        for hold in holds {
            if let lab = hold.lab {
                items.append((id: hold.id, lab: lab, area: hold.mask.pixelCount))
            }
        }
        guard !items.isEmpty else { return [] }
        items.sort { $0.area > $1.area }

        // 1) Leader pass.
        var centers: [LabColor] = []
        var sums: [(l: Double, a: Double, b: Double, n: Double)] = []
        for item in items {
            var best = -1
            var bestDistance = threshold
            for (index, center) in centers.enumerated() {
                let d = deltaE2000(center, item.lab, kL: 2)
                if d < bestDistance {
                    bestDistance = d
                    best = index
                }
            }
            if best >= 0 {
                sums[best].l += item.lab.l
                sums[best].a += item.lab.a
                sums[best].b += item.lab.b
                sums[best].n += 1
                let s = sums[best]
                centers[best] = LabColor(l: s.l / s.n, a: s.a / s.n, b: s.b / s.n)
            } else {
                centers.append(item.lab)
                sums.append((l: item.lab.l, a: item.lab.a, b: item.lab.b, n: 1))
            }
        }

        // 2) Re-assign every hold to its nearest center.
        var members: [[Int]] = Array(repeating: [], count: centers.count)
        var labSums: [(l: Double, a: Double, b: Double)] = Array(repeating: (l: 0.0, a: 0.0, b: 0.0), count: centers.count)
        for item in items {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, center) in centers.enumerated() {
                let d = deltaE2000(center, item.lab, kL: 2)
                if d < bestDistance {
                    bestDistance = d
                    best = index
                }
            }
            members[best].append(item.id)      // items are largest-first
            labSums[best].l += item.lab.l
            labSums[best].a += item.lab.a
            labSums[best].b += item.lab.b
        }

        var groups: [(lab: LabColor, ids: [Int])] = []
        for index in centers.indices where !members[index].isEmpty {
            let n = Double(members[index].count)
            let lab = LabColor(l: labSums[index].l / n, a: labSums[index].a / n, b: labSums[index].b / n)
            groups.append((lab: lab, ids: members[index]))
        }
        groups.sort { $0.ids.count > $1.ids.count }

        let names = Self.names(for: groups.map { $0.lab })
        var result: [ColorCluster] = []
        for (index, group) in groups.enumerated() {
            result.append(ColorCluster(id: index, name: names[index], lab: group.lab, holdIDs: group.ids))
        }
        return result
    }

    /// Typical plastic hold colors under gym lighting.
    private static let palette: [(name: String, lab: LabColor)] = {
        let raw: [(String, Double, Double, Double)] = [
            ("Red", 200, 35, 45), ("Orange", 240, 125, 35), ("Yellow", 245, 210, 45),
            ("Lime", 165, 210, 55), ("Green", 40, 150, 75), ("Teal", 25, 155, 155),
            ("Blue", 35, 95, 200), ("Light Blue", 120, 180, 230), ("Purple", 120, 65, 170), ("Pink", 235, 105, 170),
            ("White", 235, 235, 230), ("Gray", 130, 130, 130), ("Black", 35, 35, 38),
            ("Brown", 120, 78, 48), ("Tan", 205, 180, 140)
        ]
        return raw.map { entry in
            let rgb = RGBPixel(r: entry.1 / 255, g: entry.2 / 255, b: entry.3 / 255)
            return (name: entry.0, lab: ColorAnalyzer.rgbToLab(rgb))
        }
    }()

    /// Nearest palette name; duplicates become "Light …" / "Dark …" / numbered.
    static func names(for labs: [LabColor]) -> [String] {
        let analyzer = ColorAnalyzer()
        var base: [String] = []
        for lab in labs {
            var bestName = "Color"
            var bestDistance = Double.greatestFiniteMagnitude
            for entry in palette {
                let d = analyzer.deltaE2000(entry.lab, lab)
                if d < bestDistance {
                    bestDistance = d
                    bestName = entry.name
                }
            }
            base.append(bestName)
        }

        var result = base
        for name in Set(base) {
            let indices = base.indices.filter { base[$0] == name }
            guard indices.count > 1 else { continue }
            let byLightness = indices.sorted { labs[$0].l > labs[$1].l }
            if byLightness.count == 2 {
                result[byLightness[0]] = "Light " + name
                result[byLightness[1]] = "Dark " + name
            } else {
                for (rank, index) in byLightness.enumerated() {
                    result[index] = "\(name) \(rank + 1)"
                }
            }
        }
        return result
    }

    /// Inverse of `rgbToLab` (D65, sRGB), clamped to 0...1. Used for the
    /// little route-color swatch in the UI.
    static func labToRGB(_ lab: LabColor) -> RGBPixel {
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        func finv(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta ? t * t * t : 3 * delta * delta * (t - 4.0 / 29.0)
        }
        let x = 0.95047 * finv(fx)
        let y = finv(fy)
        let z = 1.08883 * finv(fz)

        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        return RGBPixel(
            r: gamma(3.2404542 * x - 1.5371385 * y - 0.4985314 * z),
            g: gamma(-0.9692660 * x + 1.8760108 * y + 0.0415560 * z),
            b: gamma(0.0556434 * x - 0.2040259 * y + 1.0572252 * z)
        )
    }

    /// CIEDE2000. `kL` > 1 weights lightness less (2 = tolerant of uneven
    /// lighting across a wall, used when grouping holds by color).
    func deltaE2000(_ c1: LabColor, _ c2: LabColor, kL: Double = 1) -> Double {
        let l1 = c1.l
        let a1 = c1.a
        let b1 = c1.b
        let l2 = c2.l
        let a2 = c2.a
        let b2 = c2.b

        let c1ab = hypot(a1, b1)
        let c2ab = hypot(a2, b2)
        let cBar = (c1ab + c2ab) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (
            1 - sqrt(cBar7 / (cBar7 + pow(25.0, 7)))
        )

        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1)
        let c2p = hypot(a2p, b2)

        func hue(_ a: Double, _ b: Double) -> Double {
            if abs(a) < 1e-12 && abs(b) < 1e-12 { return 0 }
            var h = atan2(b, a) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }

        let h1p = hue(a1p, b1)
        let h2p = hue(a2p, b2)
        let dLp = l2 - l1
        let dCp = c2p - c1p

        let dhp: Double
        if c1p * c2p == 0 {
            dhp = 0
        } else if abs(h2p - h1p) <= 180 {
            dhp = h2p - h1p
        } else if h2p <= h1p {
            dhp = h2p - h1p + 360
        } else {
            dhp = h2p - h1p - 360
        }

        let dHp = 2 * sqrt(c1p * c2p)
            * sin((dhp / 2) * .pi / 180)

        let lBar = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2

        let hBarP: Double
        if c1p * c2p == 0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= 180 {
            hBarP = (h1p + h2p) / 2
        } else if h1p + h2p < 360 {
            hBarP = (h1p + h2p + 360) / 2
        } else {
            hBarP = (h1p + h2p - 360) / 2
        }

        let t =
            1
            - 0.17 * cos((hBarP - 30) * .pi / 180)
            + 0.24 * cos((2 * hBarP) * .pi / 180)
            + 0.32 * cos((3 * hBarP + 6) * .pi / 180)
            - 0.20 * cos((4 * hBarP - 63) * .pi / 180)

        let deltaTheta = 30
            * exp(-pow((hBarP - 275) / 25, 2))

        let rc = 2
            * sqrt(
                pow(cBarP, 7) /
                (pow(cBarP, 7) + pow(25.0, 7))
            )

        let sl = 1
            + (0.015 * pow(lBar - 50, 2))
            / sqrt(20 + pow(lBar - 50, 2))

        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin((2 * deltaTheta) * .pi / 180) * rc

        let lTerm = dLp / (sl * kL)
        let cTerm = dCp / sc
        let hTerm = dHp / sh

        return sqrt(
            lTerm * lTerm +
            cTerm * cTerm +
            hTerm * hTerm +
            rt * cTerm * hTerm
        )
    }
}
