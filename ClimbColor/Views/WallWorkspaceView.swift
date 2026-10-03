import SwiftUI
import UIKit

// MARK: - Measuring the controls
//
// Every floating control reports its on-screen frame. The photo's "Fit"
// position is computed from what is left, so the wall is never hidden
// under buttons — in portrait or landscape.

private struct TopChromeKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

private struct BottomChromeKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

private struct TrailingChromeKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

private extension View {
    func reportFrame<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGRect {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: key, value: proxy.frame(in: .global))
            }
        )
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// System share sheet (Messages, AirDrop, Instagram…).
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Workspace

/// Library ⇄ wall viewer. The wall is edge-to-edge; controls float around it.
struct WallWorkspaceView: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var chromeHidden = false
    @State private var peekingOriginal = false
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var showCameraUnavailable = false
    @State private var showExports = false
    @State private var confirmDelete = false
    @State private var holdToRemove: Int?
    @State private var shareItem: ShareItem?
    @State private var zoomCommand: ZoomCommand?
    @State private var zoomLabel = "Fit"

    @State private var topChrome: CGRect = .null
    @State private var bottomChrome: CGRect = .null
    @State private var trailingChrome: CGRect = .null

    /// iPhone held sideways.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var showingWall: Bool { model.hasPhotos && !model.showingLibrary }

    var body: some View {
        GeometryReader { root in
            ZStack {
                Color.black.ignoresSafeArea()

                if showingWall, let image = model.image, let photo = model.current {
                    backdrop
                    WallCanvasView(
                        image: image,
                        pixelSize: photo.pixelSize,
                        holds: model.holds,
                        paths: model.holdPaths,
                        selectedID: model.anchorID,
                        routeIDs: model.routeIDs,
                        showOverlay: model.showDetection && !peekingOriginal,
                        showPeelHandle: !chromeHidden,
                        obstruction: obstruction(root: root),
                        canEdit: model.canEditHolds,
                        refiningIDs: model.refiningHoldIDs,
                        labels: model.routeLabels,
                        command: $zoomCommand,
                        zoomLabel: $zoomLabel,
                        onTapHold: { model.tapHold($0) },
                        onTapEmpty: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                        onLongPressHold: { holdToRemove = $0 },
                        onLongPressEmpty: { point, radius in model.addManualHold(at: point, radiusPixels: radius) },
                        onSwipe: { model.step(by: $0) }
                    )
                    .id(photo.id)
                    .ignoresSafeArea()
                    .transition(.opacity)

                    if chromeHidden {
                        hiddenChrome
                    } else if isLandscape {
                        landscapeChrome.transition(.opacity)
                    } else {
                        portraitChrome.transition(.opacity)
                    }
                } else {
                    LibraryView(
                        onCamera: openCamera,
                        onPhotos: { showPicker = true },
                        onExports: { showExports = true }
                    )
                }

                toastView
            }
            .frame(width: root.size.width, height: root.size.height)
            .onPreferenceChange(TopChromeKey.self) { topChrome = $0 }
            .onPreferenceChange(BottomChromeKey.self) { bottomChrome = $0 }
            .onPreferenceChange(TrailingChromeKey.self) { trailingChrome = $0 }
        }
        .animation(.easeInOut(duration: 0.18), value: model.currentID)
        .animation(.easeInOut(duration: 0.22), value: model.showingLibrary)
        .preferredColorScheme(.dark)
        .statusBarHidden(showingWall)
        .persistentSystemOverlays(chromeHidden && showingWall ? .hidden : .automatic)
        .onChange(of: model.currentID) { _, _ in zoomLabel = "Fit" }
        .onChange(of: showingWall) { _, showing in
            // Keep the screen awake while reading a wall (phone resting on the mat).
            UIApplication.shared.isIdleTimerDisabled = showing
            if showing { chromeHidden = false }
        }
        .fullScreenCover(isPresented: $showPicker) {
            PhotoPicker(
                onPicked: { count in
                    showPicker = false
                    if count > 0 {
                        chromeHidden = false
                        model.beginImport(count: count)
                    }
                },
                onLoaded: { urls, failed in
                    Task {
                        await model.importFiles(urls, expected: urls.count + failed, failed: failed)
                    }
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onImage: { image in
                    showCamera = false
                    chromeHidden = false
                    model.addCameraImage(image)
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showExports) {
            HistoryView().environmentObject(model)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.image])
                .presentationDetents([.medium, .large])
        }
        .alert("Camera Unavailable", isPresented: $showCameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use a physical iPhone to take photos, or choose them from Photos.")
        }
        .confirmationDialog("Delete this photo from the library?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteCurrentFromLibrary() }
        } message: {
            Text("Its holds and route are deleted too. Your Photos app is not affected.")
        }
        .confirmationDialog("Remove this hold?",
                            isPresented: Binding(get: { holdToRemove != nil },
                                                 set: { if !$0 { holdToRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Hold", role: .destructive) {
                if let id = holdToRemove { model.removeHold(id) }
                holdToRemove = nil
            }
        } message: {
            Text("For things that aren't holds: bolts, marks, volumes. Long-press empty wall to add a hold.")
        }
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showCameraUnavailable = true
        }
    }

    /// Screen edges covered by controls (zero when controls are hidden).
    private func obstruction(root: GeometryProxy) -> UIEdgeInsets {
        guard !chromeHidden else { return .zero }
        let safe = root.safeAreaInsets
        let screenWidth = root.size.width + safe.leading + safe.trailing
        let screenHeight = root.size.height + safe.top + safe.bottom
        let gap: CGFloat = 8

        let top: CGFloat = topChrome.isNull ? safe.top : topChrome.maxY + gap
        let bottom: CGFloat = bottomChrome.isNull ? safe.bottom : max(0, screenHeight - bottomChrome.minY + gap)
        let right: CGFloat = trailingChrome.isNull ? safe.trailing : max(0, screenWidth - trailingChrome.minX + gap)
        return UIEdgeInsets(top: top, left: safe.leading, bottom: bottom, right: right)
    }

    // MARK: Backdrop

    /// Blurred extension of the photo instead of hard black bars.
    @ViewBuilder
    private var backdrop: some View {
        if let backdrop = model.current?.backdrop {
            // The image lives in an overlay of a plain color, so its
            // scaled-to-fill size can NEVER widen the layout. (v6/v7 bug:
            // a landscape photo made the whole screen ~1.5x wider than the
            // phone in portrait, pushing the controls off to the right.)
            Color.black
                .overlay {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 30)
                }
                .overlay(Color.black.opacity(0.5))
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Layouts

    /// Upright: status on top, everything you touch at the bottom within
    /// thumb reach. Every row either scrolls or uses equal-width cells, so
    /// no button can be cut off on any iPhone width.
    private var portraitChrome: some View {
        VStack(spacing: 0) {
            statusPill
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .reportFrame(TopChromeKey.self)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                colorSection(vertical: false)
                if model.selectedID != nil { routeRow }
                if model.photos.count > 1 {
                    Filmstrip(onCamera: openCamera, onPhotos: { showPicker = true }, showAddTile: false)
                }
                dock
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: 600)
            .reportFrame(BottomChromeKey.self)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    // MARK: Dock (portrait)

    private var dock: some View {
        HStack(spacing: 0) {
            Button { model.showLibrary() } label: {
                dockLabel("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Menu {
                addMenuItems
            } label: {
                dockLabel("Add", systemImage: "plus.circle.fill", tint: Color(uiColor: HoldStyle.routeColor))
            }

            Button {
                zoomCommand = ZoomCommand(kind: zoomLabel == "Fit" ? .actualSize : .fit)
            } label: {
                dockLabel(zoomLabel == "Fit" ? "1:1" : "Fit",
                          systemImage: zoomLabel == "Fit" ? "plus.magnifyingglass" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)

            dockLabel(peekingOriginal ? "Original" : "Peek",
                      systemImage: peekingOriginal ? "eye.slash.fill" : "eye")
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}) { pressing in
                    peekingOriginal = pressing
                }
                .opacity(model.holds.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Hold to hide outlines")

            Menu {
                shareMenuItems
            } label: {
                dockLabel("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(model.holds.isEmpty)

            Menu {
                moreMenuItems
            } label: {
                dockLabel("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func dockLabel(_ title: String, systemImage: String, tint: Color = .white) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button(action: openCamera) {
            Label("Take Photo", systemImage: "camera")
        }
        Button { showPicker = true } label: {
            Label("Choose Photos…", systemImage: "photo.on.rectangle.angled")
        }
    }

    /// Sideways: one panel on the right, so the wall keeps the full height.
    private var landscapeChrome: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    libraryButton
                    Spacer(minLength: 4)
                    moreMenu
                }
                statusPill
                colorSection(vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                if model.selectedID != nil { routeRow }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    toolButtons
                    Spacer(minLength: 0)
                }
                Filmstrip(onCamera: openCamera, onPhotos: { showPicker = true })
            }
            .padding(10)
            .frame(width: 300)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            .reportFrame(TrailingChromeKey.self)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }

    /// Controls hidden: only a way back stays on screen.
    private var hiddenChrome: some View {
        VStack {
            HStack {
                CircleButton(systemImage: "chevron.left", label: "Library") { model.showLibrary() }
                    .opacity(0.8)
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: Top controls

    private var libraryButton: some View {
        Button {
            model.showLibrary()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Library")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Library")
    }

    private var statusText: String {
        if model.importingCount > 0 {
            let n = model.importingCount
            return "Adding \(n) photo\(n == 1 ? "" : "s")…"
        }
        switch model.phase {
        case .analyzing: return "Finding holds…"
        case .failed(let message): return message
        case .ready:
            if let name = model.routeName { return "\(name) · \(model.routeIDs.count)" }
            return "\(model.holds.count) holds"
        case .idle: return ""
        }
    }

    /// Status, plus ‹ › to move between open walls.
    private var statusPill: some View {
        HStack(spacing: 6) {
            if model.positionText != nil {
                Button { model.step(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .disabled(!model.canStepBack)
                .accessibilityLabel("Previous wall")
            }
            VStack(spacing: 0) {
                if let position = model.positionText {
                    Text(position)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 5) {
                    if model.isAnalyzing || model.importingCount > 0 {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(statusText)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if model.positionText != nil {
                Button { model.step(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                }
                .disabled(!model.canStepForward)
                .accessibilityLabel("Next wall")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        Toggle(isOn: $model.showDetection) {
            Label("Show Outlines", systemImage: "circle.dashed")
        }
        Picker(selection: $model.labelChoice) {
            ForEach(HoldLabelStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        } label: {
            Label("Route Labels", systemImage: "number")
        }
        .pickerStyle(.menu)
        Menu {
            Picker("Detection", selection: Binding(
                get: { model.confidence },
                set: { model.setSensitivity($0) }
            )) {
                Text("Fewer, surer holds").tag(0.30)
                Text("Balanced").tag(0.15)
                Text("Find small footholds").tag(0.07)
            }
        } label: {
            Label("Detection Sensitivity", systemImage: "dial.medium")
        }
        Button { model.redetectCurrent() } label: {
            Label("Detect Again", systemImage: "arrow.clockwise")
        }
        .disabled(model.isAnalyzing || model.modelState != .ready)
        Divider()
        Button { model.closeCurrentPhoto() } label: {
            Label("Close This Wall", systemImage: "xmark.circle")
        }
        Button { model.closeAllWalls() } label: {
            Label("Close All Walls", systemImage: "rectangle.stack.badge.minus")
        }
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("Delete from Library", systemImage: "trash")
        }
    }

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            CircleIcon(systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    // MARK: Colors (the main way to pick a route)

    @ViewBuilder
    private func colorSection(vertical: Bool) -> some View {
        switch model.phase {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Finding holds and colors…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            EmptyView()
        case .ready:
            if model.clusters.isEmpty {
                Text("No holds found. Long-press the wall to add one.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if model.selectedID == nil {
                        Text("Pick a color · or tap a hold · long-press to add or remove")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                    if vertical {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                                ForEach(model.clusters) { cluster in colorChip(cluster) }
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.clusters) { cluster in colorChip(cluster) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func colorChip(_ cluster: ColorCluster) -> some View {
        let selected = model.selectedCluster?.id == cluster.id
        let sent = model.sentColorNames.contains(cluster.name)
        let rgb = ColorAnalyzer.labToRGB(cluster.lab)
        let swatch = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        return Button {
            model.selectCluster(cluster.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(swatch)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                if sent {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                }
                Text(cluster.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(cluster.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.white : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.name), \(cluster.count) holds\(sent ? ", sent" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var routeRow: some View {
        let send = model.currentRouteSend
        let subtitle: String
        if let send {
            subtitle = "Sent " + send.date.formatted(.dateTime.month(.abbreviated).day())
        } else if model.isEditingRoute {
            subtitle = "Tap holds to add or remove"
        } else {
            subtitle = "Missing a hold? Long-press it"
        }

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.routeName ?? "Route") · \(model.routeIDs.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(send == nil ? Color.white.opacity(0.7) : Color.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)

            Spacer(minLength: 2)

            // Record a completed route (tap again to undo).
            Button {
                model.toggleSent()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: send == nil ? "checkmark.seal" : "checkmark.seal.fill")
                    Text(send == nil ? "Sent?" : "Sent")
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(send == nil ? Color.white : Color.black)
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(send == nil ? Color.white.opacity(0.14) : Color.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(send == nil ? "Mark route as sent" : "Sent. Tap to undo")

            // Labels on/off right where they are read. Long-press: 1 2 3 ⇄ A B C.
            Button {
                model.toggleLabels()
            } label: {
                Text(model.labelStyle == .letters ? "ABC" : "123")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(model.showLabels ? Color.black : Color.white.opacity(0.75))
                    .strikethrough(!model.showLabels, color: .white)
                    .frame(width: 38, height: 38)
                    .background(model.showLabels ? Color.white : Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Picker("Labels", selection: $model.labelChoice) {
                    ForEach(HoldLabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
            .accessibilityLabel(model.showLabels ? "Hide hold labels" : "Show hold labels")

            Button {
                model.isEditingRoute.toggle()
            } label: {
                Image(systemName: model.isEditingRoute ? "checkmark" : "pencil")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(model.isEditingRoute ? Color.black : Color.white)
                    .frame(width: 38, height: 38)
                    .background(model.isEditingRoute
                                ? Color(uiColor: HoldStyle.selectedColor)
                                : Color.white.opacity(0.14),
                                in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isEditingRoute ? "Done editing" : "Edit route holds")

            Button {
                withAnimation(.snappy) { model.clearRoute() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear route")
        }
    }

    // MARK: Tools

    private var toolButtons: some View {
        HStack(spacing: 8) {
            zoomButton
            peekButton
            shareMenu
        }
    }

    /// Fit ⇄ 100% of the original photo's pixels.
    private var zoomButton: some View {
        Button {
            zoomCommand = ZoomCommand(kind: zoomLabel == "Fit" ? .actualSize : .fit)
        } label: {
            Text(zoomLabel == "Fit" ? "1:1" : "Fit")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(zoomLabel == "Fit" ? "Zoom to original pixels" : "Fit whole photo")
    }

    /// Press and hold to see the bare wall; release to bring outlines back.
    private var peekButton: some View {
        Image(systemName: peekingOriginal ? "eye.slash.fill" : "eye")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.white.opacity(0.14)))
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}) { pressing in
                peekingOriginal = pressing
            }
            .accessibilityLabel("Hold to hide outlines")
            .opacity(model.holds.isEmpty ? 0.4 : 1)
    }

    @ViewBuilder
    private var shareMenuItems: some View {
        Button {
            Task {
                if let image = await model.imageForSharing() {
                    shareItem = ShareItem(image: image)
                }
            }
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        Button { model.saveCompositeToPhotos() } label: {
            Label("Save Image to Photos", systemImage: "photo")
        }
        Section("Transparent PNG layer") {
            Button { model.saveLayerToPhotos(routeOnly: false) } label: {
                Label("All Outlines", systemImage: "square.3.layers.3d")
            }
            Button { model.saveLayerToPhotos(routeOnly: true) } label: {
                Label("Route Only", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .disabled(model.selectedID == nil)
        }
    }

    private var shareMenu: some View {
        Menu {
            shareMenuItems
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .disabled(model.holds.isEmpty)
        .accessibilityLabel("Share or save")
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toast).lineLimit(2)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(.top, 56)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .task(id: toast) {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation { if model.toast == toast { model.toast = nil } }
            }
        }
    }
}

// MARK: - Filmstrip

/// Every open wall, plus a permanent "Add" tile (camera or any number of
/// photos from the library).
private struct Filmstrip: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let onCamera: () -> Void
    let onPhotos: () -> Void
    var showAddTile = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if showAddTile { addTile }
                    ForEach(model.photos) { photo in
                        thumbnail(photo)
                            .id(photo.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.currentID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 48)
    }

    private var addTile: some View {
        Menu {
            Button(action: onCamera) {
                Label("Take Photo", systemImage: "camera")
            }
            Button(action: onPhotos) {
                Label("Choose Photos…", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("Add")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(width: 44, height: 44)
            .background(Color(uiColor: HoldStyle.routeColor),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .accessibilityLabel("Add photos")
    }

    private func thumbnail(_ photo: WallPhoto) -> some View {
        let selected = photo.id == model.currentID
        return Button {
            model.select(photo.id)
        } label: {
            ZStack {
                if let thumb = photo.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()   // thumbnail only; the wall itself is never cropped
                } else {
                    Color.gray.opacity(0.3)
                }
                statusBadge(photo)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.white : Color.clear, lineWidth: 2.5)
            )
            .opacity(selected ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.select(photo.id)
                model.closeCurrentPhoto()
            } label: {
                Label("Close Wall", systemImage: "xmark.circle")
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ photo: WallPhoto) -> some View {
        switch photo.status {
        case .pending, .analyzing:
            ZStack {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small).tint(.white)
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.35)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        case .ready:
            if photo.selectedID != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color(uiColor: HoldStyle.selectedColor))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                            .padding(3)
                    }
                }
            }
        }
    }
}

// MARK: - Small components

struct CircleIcon: View {
    let systemImage: String
    var size: CGFloat = 38
    var highlighted = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(highlighted ? .black : .white)
            .frame(width: size, height: size)
            .background {
                if highlighted {
                    Circle().fill(Color(uiColor: HoldStyle.selectedColor))
                } else {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .environment(\.colorScheme, .dark)
            .contentShape(Circle())
    }
}

struct CircleButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIcon(systemImage: systemImage, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
