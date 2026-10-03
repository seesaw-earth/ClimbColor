import SwiftUI
import UIKit

/// Photo zooming built on UIScrollView (native pinch / pan / momentum).
///
/// - Never crops: "Fit" shows the whole photo, landscape or portrait.
/// - `obstruction` = screen edges covered by controls. Fit places the photo
///   inside the uncovered area, so nothing important hides under buttons.
/// - Free panning: the photo stays where it is dropped.
/// - Max zoom: 200% of the ORIGINAL pixels.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Original photo size in pixels (may be larger than `image` while the
    /// full-resolution version is still loading).
    let pixelSize: CGSize
    var obstruction: UIEdgeInsets = .zero
    @Binding var command: ZoomCommand?
    var onRectChange: (CGRect) -> Void = { _ in }
    var onZoomingChange: (Bool) -> Void = { _ in }
    var onTap: ((CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?
    var onSwipe: ((Int) -> Void)?

    final class Coordinator {
        var lastToken: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomContainerView {
        let view = ZoomContainerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ZoomContainerView, context: Context) {
        apply(to: view)
        if let command, command.token != context.coordinator.lastToken {
            context.coordinator.lastToken = command.token
            view.performZoom(command.kind)
            let binding = $command
            DispatchQueue.main.async { binding.wrappedValue = nil }
        }
    }

    static func dismantleUIView(_ view: ZoomContainerView, coordinator: Coordinator) {
        view.stopDisplayLink()
    }

    private func apply(to view: ZoomContainerView) {
        view.onRectChange = onRectChange
        view.onZoomingChange = onZoomingChange
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onSwipe = onSwipe
        view.configure(image: image, pixelSize: pixelSize)
        view.setObstruction(obstruction)
    }
}

final class ZoomContainerView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    var onRectChange: ((CGRect) -> Void)?
    var onZoomingChange: ((Bool) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onLongPress: ((CGPoint) -> Void)?
    var onSwipe: ((Int) -> Void)?

    private var pixelSize: CGSize = .zero
    private var obstruction: UIEdgeInsets = .zero
    private var lastLayoutSize: CGSize = .zero
    private var layoutTime: CFTimeInterval = 0
    private var lastReportedRect: CGRect = .null
    private var displayLink: CADisplayLink?
    private var wasZooming = false
    private var animatingUntil: CFTimeInterval = 0
    /// Separate delegate object: UIView already defines
    /// `gestureRecognizerShouldBegin(_:)`, so the view itself can't be it.
    private let swipeGate = SwipeGate()

    /// How much of the photo must stay on screen while dragging freely.
    private let keepVisible: CGFloat = 96
    /// false (default): auto-fit — the photo is centred in the uncovered
    /// area and, when zoomed, its edges snap to that area (no drifting,
    /// no empty gaps). true: the user dragged the photo at Fit, so it stays
    /// exactly where they put it. Pinching back out / Fit returns to auto-fit.
    private var freePan = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.bouncesZoom = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        // Lets a drag start even when the whole photo fits (to move it aside).
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true

        imageView.contentMode = .scaleToFill      // frame already has the photo's aspect ratio
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)
        addSubview(scrollView)

        swipeGate.canSwipe = { [weak self] in
            guard let self else { return false }
            return self.onSwipe != nil && self.isAtFit
        }

        // No double-tap: single taps on holds respond instantly.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        scrollView.addGestureRecognizer(longPress)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = swipeGate
            scrollView.addGestureRecognizer(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Content

    func configure(image: UIImage, pixelSize: CGSize) {
        if imageView.image !== image {
            imageView.image = image
        }
        if self.pixelSize != pixelSize {
            self.pixelSize = pixelSize
            lastLayoutSize = .zero
            setNeedsLayout()
        }
    }

    func setObstruction(_ insets: UIEdgeInsets) {
        guard insets != obstruction else { return }
        let wasAtFit = isAtFit
        obstruction = insets
        guard lastLayoutSize != .zero else { return }

        scrollView.minimumZoomScale = minScale()
        if (wasAtFit && !freePan) || scrollView.zoomScale < scrollView.minimumZoomScale {
            // Just appeared: no animation (avoids a jump on first layout).
            let animated = CACurrentMediaTime() - layoutTime > 0.4
            fitToFreeArea(animated: animated)
        } else {
            updateInsets()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard
            bounds.width > 0, bounds.height > 0,
            pixelSize.width > 0, pixelSize.height > 0,
            bounds.size != lastLayoutSize
        else { return }

        // First layout or rotation: whole photo, centred in the free area.
        lastLayoutSize = bounds.size
        layoutTime = CACurrentMediaTime()
        freePan = false
        let base = baseFit()
        scrollView.minimumZoomScale = min(1, minScale())
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: base)
        scrollView.contentSize = base
        scrollView.maximumZoomScale = maxScale()
        scrollView.minimumZoomScale = minScale()
        scrollView.zoomScale = scrollView.minimumZoomScale
        updateInsets()
        scrollView.contentOffset = centeredOffset()
        DispatchQueue.main.async { [weak self] in self?.reportRect(force: true) }
    }

    // MARK: Geometry

    /// The part of the screen not covered by controls.
    private func freeRect() -> CGRect {
        let free = bounds.inset(by: obstruction)
        guard free.width >= 120, free.height >= 120 else { return bounds }
        return free
    }

    /// Photo size at zoomScale 1 (aspect-fit to the whole screen).
    private func baseFit() -> CGSize {
        let k = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        return CGSize(width: pixelSize.width * k, height: pixelSize.height * k)
    }

    /// Zoom scale at which the whole photo fits the free area.
    private func minScale() -> CGFloat {
        let free = freeRect()
        let base = baseFit()
        guard base.width > 0 else { return 1 }
        let k = min(free.width / pixelSize.width, free.height / pixelSize.height)
        return min(1, pixelSize.width * k / base.width)
    }

    private var screenScale: CGFloat { max(traitCollection.displayScale, 1) }

    /// Zoom scale at which 1 photo pixel = 1 screen pixel ("100%").
    private func actualScale() -> CGFloat {
        let base = baseFit()
        guard base.width > 0 else { return 1 }
        return pixelSize.width / (base.width * screenScale)
    }

    private func maxScale() -> CGFloat { max(4, actualScale() * 2) }

    private var isAtFit: Bool {
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }

    private func updateInsets() {
        let size = scrollView.bounds.size
        let content = scrollView.contentSize
        if freePan {
            // Stays wherever it is dropped, as long as `keepVisible` points remain.
            let x = max(0, size.width - min(keepVisible, content.width))
            let y = max(0, size.height - min(keepVisible, content.height))
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        } else {
            // Auto-fit: centred in the uncovered area when smaller than it;
            // when zoomed, the edges stop exactly at the uncovered area.
            let free = freeRect()
            let extraX = max(0, (free.width - content.width) / 2)
            let extraY = max(0, (free.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: max(0, free.minY + extraY),
                left: max(0, free.minX + extraX),
                bottom: max(0, size.height - free.maxY + extraY),
                right: max(0, size.width - free.maxX + extraX))
        }
    }

    /// Offset that puts the photo's centre at the centre of the free area.
    private func centeredOffset() -> CGPoint {
        let free = freeRect()
        let content = scrollView.contentSize
        return CGPoint(x: content.width / 2 - free.midX,
                       y: content.height / 2 - free.midY)
    }

    private func fitToFreeArea(animated: Bool) {
        freePan = false
        let changes = {
            self.scrollView.zoomScale = self.scrollView.minimumZoomScale
            self.updateInsets()
            self.scrollView.contentOffset = self.centeredOffset()
        }
        if animated {
            markAnimating()
            UIView.animate(withDuration: 0.32, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                           animations: changes)
        } else {
            changes()
            reportRect(force: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        reportRect(force: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportRect(force: false)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Dragging the whole photo = "move it out of the way": keep it there.
        if !freePan && isAtFit {
            freePan = true
            updateInsets()
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Pinching all the way back out re-centres the whole photo.
        if scale <= scrollView.minimumZoomScale + 0.01 {
            fitToFreeArea(animated: true)
        }
    }

    // MARK: Reporting the photo's on-screen rect (for the SwiftUI outlines)

    /// Uses presentation layers so the rect is correct mid-animation too.
    private func currentImageRect() -> CGRect {
        let imageLayer = imageView.layer.presentation() ?? imageView.layer
        let scrollLayer = scrollView.layer.presentation() ?? scrollView.layer
        let frame = imageLayer.frame
        let origin = scrollLayer.bounds.origin
        return CGRect(x: frame.minX - origin.x, y: frame.minY - origin.y,
                      width: frame.width, height: frame.height)
    }

    private func reportRect(force: Bool) {
        let rect = currentImageRect()
        let last = lastReportedRect
        let changed = last.isNull
            || abs(rect.minX - last.minX) > 0.2 || abs(rect.minY - last.minY) > 0.2
            || abs(rect.width - last.width) > 0.2 || abs(rect.height - last.height) > 0.2
        if force || changed {
            lastReportedRect = rect
            onRectChange?(rect)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopDisplayLink() } else { startDisplayLink() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        reportRect(force: false)
        let zooming = scrollView.isZooming || scrollView.isZoomBouncing
            || CACurrentMediaTime() < animatingUntil
        if zooming != wasZooming {
            wasZooming = zooming
            onZoomingChange?(zooming)
        }
    }

    // MARK: Zoom actions

    private func markAnimating() {
        animatingUntil = CACurrentMediaTime() + 0.5
    }

    func performZoom(_ kind: ZoomCommand.Kind) {
        switch kind {
        case .fit:
            fitToFreeArea(animated: true)
        case .actualSize:
            let target = min(max(actualScale(), scrollView.minimumZoomScale * 2.5),
                             scrollView.maximumZoomScale)
            let free = freeRect()
            let center = imageView.convert(CGPoint(x: free.midX, y: free.midY), from: self)
            let w = scrollView.bounds.width / target
            let h = scrollView.bounds.height / target
            markAnimating()
            scrollView.zoom(to: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h),
                            animated: true)
        }
    }

    // MARK: Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onLongPress?(gesture.location(in: self))
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onSwipe?(gesture.direction == .left ? 1 : -1)
    }
}

/// Lets the photo-swipe recognizers fire only at Fit, alongside the
/// scroll view's own pan/pinch recognizers.
private final class SwipeGate: NSObject, UIGestureRecognizerDelegate {
    var canSwipe: () -> Bool = { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        canSwipe()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
