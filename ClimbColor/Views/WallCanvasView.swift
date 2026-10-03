import SwiftUI
import UIKit

/// A zoom request from outside the canvas (the Fit / 1:1 button).
struct ZoomCommand: Equatable {
    enum Kind { case fit, actualSize }
    let kind: Kind
    let token = UUID()
}

/// Edge-to-edge wall: the photo (zoomed natively by UIScrollView), its
/// detection "membrane" drawn as vector outlines on top, and the peel tab.
struct WallCanvasView: View {
    let image: UIImage
    let pixelSize: CGSize
    let holds: [HoldInstance]
    let paths: [Int: Path]
    let selectedID: Int?
    let routeIDs: Set<Int>
    let showOverlay: Bool
    let showPeelHandle: Bool
    /// Screen edges covered by controls; Fit keeps the photo out from under them.
    let obstruction: UIEdgeInsets
    /// Holds are ready and can be added/removed with a long-press.
    let canEdit: Bool
    /// Hand-added holds still being re-detected (drawn with a dashed ring).
    let refiningIDs: Set<Int>
    /// Route order badges ("1", "2"… or "A", "B"…), bottom → top.
    let labels: [Int: String]
    @Binding var command: ZoomCommand?
    /// "Fit" or e.g. "100%", relative to the original pixels.
    @Binding var zoomLabel: String
    let onTapHold: (Int) -> Void
    let onTapEmpty: () -> Void
    /// Long-press on an existing hold.
    let onLongPressHold: (Int) -> Void
    /// Long-press on empty wall: normalized point + circle radius in photo pixels.
    let onLongPressEmpty: (CGPoint, CGFloat) -> Void
    /// +1 = next photo, -1 = previous (swipe while showing the whole photo).
    let onSwipe: (Int) -> Void

    @Environment(\.displayScale) private var displayScale

    /// Where the photo currently is on screen (updated every frame by UIKit).
    @State private var imageRect: CGRect = .zero
    @State private var showZoomBadge = false
    @State private var peelX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                ZoomableImageView(
                    image: image,
                    pixelSize: pixelSize,
                    obstruction: obstruction,
                    command: $command,
                    onRectChange: { rect in
                        imageRect = rect
                        updateZoomLabel(size: size)
                    },
                    onZoomingChange: { zooming in
                        withAnimation(.easeOut(duration: zooming ? 0.15 : 0.4)) {
                            showZoomBadge = zooming
                        }
                    },
                    onTap: { location in handleTap(at: location) },
                    onLongPress: { location in handleLongPress(at: location) },
                    onSwipe: onSwipe
                )

                if showOverlay, !holds.isEmpty, imageRect.width > 0 {
                    ZStack(alignment: .topLeading) {
                        overlay(screenRect: imageRect)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                        labelLayer(rect: imageRect, size: size)
                    }
                    .frame(width: size.width, height: size.height)
                        .mask(alignment: .topLeading) {
                            // .position() makes this view full-screen, so the
                            // mask is in screen coordinates.
                            Rectangle().frame(width: peelX ?? size.width, height: size.height)
                        }
                        .allowsHitTesting(false)

                    if let peelX {
                        Rectangle()
                            .fill(.white.opacity(0.9))
                            .frame(width: 2, height: size.height)
                            .position(x: peelX, y: size.height / 2)
                            .allowsHitTesting(false)
                    }
                }

                if showOverlay, showPeelHandle || peelX != nil, !holds.isEmpty {
                    peelHandle(size: size)
                }

                if showZoomBadge {
                    Text(percentText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .position(x: (obstruction.left + size.width - obstruction.right) / 2,
                                  y: obstruction.top + 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(.named("wall"))
        }
    }

    // MARK: Zoom label

    private var percentText: String {
        guard pixelSize.width > 0 else { return "" }
        let percent = imageRect.width * displayScale / pixelSize.width * 100
        return "\(Int(percent.rounded()))%"
    }

    private func updateZoomLabel(size: CGSize) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let freeWidth = max(1, size.width - obstruction.left - obstruction.right)
        let freeHeight = max(1, size.height - obstruction.top - obstruction.bottom)
        let k = min(freeWidth / pixelSize.width, freeHeight / pixelSize.height)
        let fitWidth = pixelSize.width * k
        let atFit = imageRect.width <= fitWidth * 1.01
        let label = atFit ? "Fit" : percentText
        if label != zoomLabel { zoomLabel = label }
    }

    // MARK: Taps

    private func handleTap(at location: CGPoint) {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, !holds.isEmpty, showOverlay else {
            onTapEmpty()
            return
        }
        let p = CGPoint(x: (location.x - rect.minX) / rect.width,
                        y: (location.y - rect.minY) / rect.height)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else {
            onTapEmpty()
            return
        }

        // 1) Smallest hold whose mask is directly under the finger.
        let direct = holds
            .filter { $0.mask.contains(normalized: p) }
            .min { area($0.normalizedBounds) < area($1.normalizedBounds) }
        if let direct { onTapHold(direct.id); return }

        // 2) Fingertip tolerance (~16 pt on screen) for tiny footholds.
        let tx = 16 / rect.width, ty = 16 / rect.height
        let near = holds
            .filter { $0.normalizedBounds.insetBy(dx: -tx, dy: -ty).contains(p) }
            .min { distance($0, p, rect) < distance($1, p, rect) }
        if let near { onTapHold(near.id) } else { onTapEmpty() }
    }

    private func handleLongPress(at location: CGPoint) {
        let rect = imageRect
        guard canEdit, showOverlay, rect.width > 0, rect.height > 0 else { return }
        let p = CGPoint(x: (location.x - rect.minX) / rect.width,
                        y: (location.y - rect.minY) / rect.height)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }

        let hit = holds
            .filter { $0.mask.contains(normalized: p) }
            .min { area($0.normalizedBounds) < area($1.normalizedBounds) }
        if let hit {
            onLongPressHold(hit.id)
        } else {
            // ~18 pt circle on screen, whatever the zoom level.
            let radius = max(6, 18 * pixelSize.width / rect.width)
            onLongPressEmpty(p, radius)
        }
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func distance(_ hold: HoldInstance, _ p: CGPoint, _ rect: CGRect) -> CGFloat {
        let b = hold.normalizedBounds
        return hypot((b.midX - p.x) * rect.width, (b.midY - p.y) * rect.height)
    }

    // MARK: Drawing

    private struct Bucket: Identifiable {
        let id: Int
        let style: HoldStyle
        let factor: CGFloat
        let path: Path
    }

    /// Holds grouped by role and line-weight class -> a handful of shapes
    /// instead of hundreds of views.
    private func buckets(screenRect: CGRect) -> [Bucket] {
        var grouped: [Int: (HoldRole, CGFloat, Path)] = [:]
        for hold in holds {
            guard let unit = paths[hold.id] else { continue }
            let role = HoldRole.of(id: hold.id, selectedID: selectedID, routeIDs: routeIDs)
            let b = hold.normalizedBounds
            let k = HoldStyle.sizeFactor(for: CGRect(
                x: 0, y: 0, width: b.width * screenRect.width, height: b.height * screenRect.height))
            let kClass = k < 0.7 ? 0 : (k < 0.9 ? 1 : 2)
            let key = role.rawValue * 10 + kClass
            var entry = grouped[key] ?? (role, [0.6, 0.8, 1.0][kClass], Path())
            entry.2.addPath(unit)
            grouped[key] = entry
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { Bucket(id: $0.key, style: HoldStyle.style(for: $0.value.0),
                          factor: $0.value.1, path: $0.value.2) }
    }

    private struct LabelItem: Identifiable {
        let id: Int
        let text: String
        let point: CGPoint
    }

    /// One badge at the top-left of each labeled hold, in screen space so it
    /// stays the same readable size at every zoom level.
    private func labelLayer(rect: CGRect, size: CGSize) -> some View {
        var items: [LabelItem] = []
        if !labels.isEmpty {
            for hold in holds {
                guard let text = labels[hold.id] else { continue }
                let b = hold.outlineBounds
                let point = CGPoint(x: rect.minX + b.minX * rect.width,
                                    y: rect.minY + b.minY * rect.height)
                items.append(LabelItem(id: hold.id, text: text, point: point))
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                Text(item.text)
                    .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(Color.black.opacity(0.75), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .fixedSize()
                    .position(item.point)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func refiningPath() -> Path {
        var path = Path()
        for id in refiningIDs {
            if let unit = paths[id] { path.addPath(unit) }
        }
        return path
    }

    private func overlay(screenRect: CGRect) -> some View {
        ZStack {
            ForEach(buckets(screenRect: screenRect)) { bucket in
                let shape = UnitPathShape(unitPath: bucket.path)
                let s = bucket.style
                if let fill = s.fill {
                    shape.fill(Color(uiColor: fill), style: FillStyle(eoFill: true))
                }
                if let halo = s.halo {
                    shape.stroke(Color(uiColor: halo), style: StrokeStyle(
                        lineWidth: s.haloWidth * bucket.factor, lineCap: .round, lineJoin: .round))
                }
                shape.stroke(Color(uiColor: s.stroke), style: StrokeStyle(
                    lineWidth: s.width * bucket.factor, lineCap: .round, lineJoin: .round))
            }
            if !refiningIDs.isEmpty {
                UnitPathShape(unitPath: refiningPath())
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5]))
            }
        }
    }

    // MARK: Membrane

    /// Grab the tab on the right edge and drag left to peel the detection
    /// layer off the photo; let go and it snaps back.
    private func peelHandle(size: CGSize) -> some View {
        let x = peelX ?? size.width - obstruction.right - 10
        return Capsule()
            .fill(.white.opacity(peelX == nil ? 0.75 : 1))
            .frame(width: 5, height: 54)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(.horizontal, 14)          // bigger touch target
            .padding(.vertical, 20)
            .contentShape(Rectangle())
            .position(x: x, y: (obstruction.top + size.height - obstruction.bottom) / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("wall"))
                    .onChanged { value in
                        peelX = min(max(value.location.x, 0), size.width)
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.35)) { peelX = nil }
                    }
            )
            .accessibilityLabel("Peel detection layer")
    }
}

/// A path stored in unit space (0...1) and scaled to whatever rect it is laid
/// out in. Because Shape paths are recomputed during animations, the outline
/// tracks the photo frame-by-frame.
struct UnitPathShape: Shape {
    let unitPath: Path

    func path(in rect: CGRect) -> Path {
        unitPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
    }
}
