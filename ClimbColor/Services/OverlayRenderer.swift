import CoreGraphics
import UIKit

/// Visual language: outline first, almost no fill, so the hold's real color
/// stays visible. A thin dark halo keeps the line readable on any wall.
struct HoldStyle {
    let stroke: UIColor
    let width: CGFloat          // points on screen
    let halo: UIColor?
    let haloWidth: CGFloat
    let fill: UIColor?

    static let routeColor = UIColor(red: 0.39, green: 0.86, blue: 1.0, alpha: 1)
    static let selectedColor = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)

    static func style(for role: HoldRole) -> HoldStyle {
        switch role {
        case .idle:
            return HoldStyle(
                stroke: UIColor.white.withAlphaComponent(0.92), width: 1.3,
                halo: UIColor.black.withAlphaComponent(0.55), haloWidth: 3.0,
                fill: nil)
        case .dimmed:
            return HoldStyle(
                stroke: UIColor.white.withAlphaComponent(0.30), width: 0.8,
                halo: nil, haloWidth: 0,
                fill: nil)
        case .route:
            return HoldStyle(
                stroke: routeColor, width: 2.2,
                halo: UIColor.black.withAlphaComponent(0.65), haloWidth: 4.6,
                fill: routeColor.withAlphaComponent(0.13))
        case .selected:
            return HoldStyle(
                stroke: selectedColor, width: 2.6,
                halo: UIColor.black.withAlphaComponent(0.7), haloWidth: 5.2,
                fill: selectedColor.withAlphaComponent(0.16))
        }
    }

    /// Thinner lines on tiny footholds so the outline doesn't bury them.
    static func sizeFactor(for bounds: CGRect) -> CGFloat {
        let side = min(bounds.width, bounds.height)
        return min(1, max(0.55, side / 14))
    }
}

struct OverlayRenderer {
    enum LayerContent { case all, routeOnly }

    /// Photo + outlines at the photo's native resolution.
    func composite(
        original: UIImage,
        holds: [HoldInstance],
        selectedID: Int?,
        routeIDs: Set<Int>,
        caption: String?,
        labels: [Int: String] = [:]
    ) -> UIImage {
        let image = original.normalizedForProcessing()
        let size = image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            draw(holds: holds, selectedID: selectedID, routeIDs: routeIDs,
                 content: .all, size: size, in: ctx.cgContext)
            drawLabels(labels, holds: holds, size: size, in: ctx.cgContext)
            if let caption { drawCaption(caption, size: size, in: ctx.cgContext) }
        }
    }

    /// Transparent PNG of just the outlines — the "membrane" on its own.
    func layerPNG(
        size: CGSize,
        holds: [HoldInstance],
        selectedID: Int?,
        routeIDs: Set<Int>,
        content: LayerContent,
        labels: [Int: String] = [:]
    ) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            draw(holds: holds, selectedID: selectedID, routeIDs: routeIDs,
                 content: content, size: size, in: ctx.cgContext)
            drawLabels(labels, holds: holds, size: size, in: ctx.cgContext)
        }
    }

    /// Round badges ("1", "A", …) at the top-left of each labeled hold,
    /// matching what is shown on screen.
    private func drawLabels(_ labels: [Int: String], holds: [HoldInstance],
                            size: CGSize, in cg: CGContext) {
        guard !labels.isEmpty else { return }
        let unit = max(size.width, size.height) / 700
        let fontSize = 12 * unit
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: UIColor.black
        ]
        UIGraphicsPushContext(cg)
        defer { UIGraphicsPopContext() }

        for hold in holds {
            guard let text = labels[hold.id] else { continue }
            let b = hold.outlineBounds
            let center = CGPoint(x: b.minX * size.width, y: b.minY * size.height)
            let textSize = (text as NSString).size(withAttributes: attributes)
            let height = fontSize * 1.7
            let width = max(height, textSize.width + fontSize * 0.9)
            let badge = CGRect(x: center.x - width / 2, y: center.y - height / 2,
                               width: width, height: height)
            let path = UIBezierPath(roundedRect: badge, cornerRadius: height / 2)
            UIColor.white.setFill()
            path.fill()
            UIColor.black.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1.2 * unit
            path.stroke()
            (text as NSString).draw(
                at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                withAttributes: attributes)
        }
    }

    private func draw(
        holds: [HoldInstance],
        selectedID: Int?,
        routeIDs: Set<Int>,
        content: LayerContent,
        size: CGSize,
        in cg: CGContext
    ) {
        // Line widths scale with the photo so exports look like the screen.
        let unit = max(size.width, size.height) / 700
        var transform = CGAffineTransform(scaleX: size.width, y: size.height)

        // Built step by step with explicit types: the one-line map/filter/sorted
        // chain timed out the Swift type checker.
        var ordered: [(hold: HoldInstance, role: HoldRole)] = []
        ordered.reserveCapacity(holds.count)
        for hold in holds {
            let role: HoldRole = HoldRole.of(id: hold.id, selectedID: selectedID, routeIDs: routeIDs)
            let include: Bool = content == .all || role == .route || role == .selected
            if include { ordered.append((hold: hold, role: role)) }
        }
        ordered.sort { (a: (hold: HoldInstance, role: HoldRole), b: (hold: HoldInstance, role: HoldRole)) -> Bool in
            a.role < b.role
        }

        cg.setLineJoin(.round)
        cg.setLineCap(.round)

        for (hold, role) in ordered {
            let unitPath = hold.contours.isEmpty
                ? CGPath(rect: hold.normalizedBounds, transform: nil)
                : ContourBuilder.path(for: hold.contours)
            guard let path = unitPath.copy(using: &transform) else { continue }

            let style = HoldStyle.style(for: role)
            let box: CGRect = path.boundingBox
            let boxInPoints = CGRect(x: 0, y: 0, width: box.width / unit, height: box.height / unit)
            let k: CGFloat = HoldStyle.sizeFactor(for: boxInPoints)

            if let fill = style.fill {
                cg.addPath(path)
                cg.setFillColor(fill.cgColor)
                cg.fillPath(using: .evenOdd)
            }
            if let halo = style.halo {
                cg.addPath(path)
                cg.setStrokeColor(halo.cgColor)
                cg.setLineWidth(style.haloWidth * k * unit)
                cg.strokePath()
            }
            cg.addPath(path)
            cg.setStrokeColor(style.stroke.cgColor)
            cg.setLineWidth(style.width * k * unit)
            cg.strokePath()
        }
    }

    private func drawCaption(_ text: String, size: CGSize, in cg: CGContext) {
        let fontSize = max(16, min(40, size.width / 40))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let pad = fontSize * 0.5
        let box = CGRect(x: fontSize * 0.8, y: fontSize * 0.8,
                         width: textSize.width + pad * 2,
                         height: textSize.height + pad * 0.9)
        cg.addPath(UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).cgPath)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        cg.fillPath()
        UIGraphicsPushContext(cg)
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad * 0.45),
                  withAttributes: attributes)
        UIGraphicsPopContext()
    }
}
