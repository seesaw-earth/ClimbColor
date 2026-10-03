import SwiftUI
import UIKit

/// One wall photo open in the viewer. Each keeps its own holds, color
/// groups and route, so you can flip between walls freely.
struct WallPhoto: Identifiable, @unchecked Sendable {
    enum Status: Equatable { case pending, analyzing, ready, failed(String) }

    let id: UUID
    let fileURL: URL
    let pixelSize: CGSize
    let thumbnail: UIImage?
    let backdrop: UIImage?
    var status: Status = .pending
    var holds: [HoldInstance] = []
    var holdPaths: [Int: Path] = [:]
    var clusters: [ColorCluster] = []
    /// A hold in the route (the one tapped, or the first of the color group).
    var selectedID: Int?
    /// false when the route was picked with a color button: no hold is
    /// singled out in yellow then.
    var anchorVisible = true
    var autoRouteIDs: Set<Int> = []
    var addedIDs: Set<Int> = []
    var removedIDs: Set<Int> = []
    var analysisConfidence: Double = 0.15

    var routeIDs: Set<Int> {
        guard let selectedID else { return [] }
        var ids: Set<Int> = autoRouteIDs.union(addedIDs).subtracting(removedIDs)
        ids.insert(selectedID)
        return ids
    }

    var anchorID: Int? { anchorVisible ? selectedID : nil }

    func cluster(containing holdID: Int) -> ColorCluster? {
        clusters.first { $0.holdIDs.contains(holdID) }
    }

    /// Replaces the holds and rebuilds outlines and color groups.
    mutating func setHolds(_ newHolds: [HoldInstance]) {
        holds = newHolds
        holdPaths = Self.makePaths(newHolds)
        clusters = ColorAnalyzer().clusters(for: newHolds)
    }

    /// Opens a library record, reusing its saved analysis and route if any.
    static func load(record: WallRecord, library: WallLibrary) -> WallPhoto {
        let url = library.photoURL(for: record)
        let thumb: UIImage? = library.thumbnail(for: record.id)
            ?? PhotoFiles.image(at: url, maxPixel: 360)
        var photo = WallPhoto(id: record.id, fileURL: url, pixelSize: record.pixelSize,
                              thumbnail: thumb, backdrop: thumb)

        if let analysis = library.loadAnalysis(for: record.id) {
            let holds: [HoldInstance] = analysis.holds.compactMap { $0.instance() }
            photo.setHolds(holds)
            photo.analysisConfidence = analysis.confidence
            photo.status = .ready
            if let route = record.route, holds.contains(where: { $0.id == route.selectedID }) {
                photo.selectedID = route.selectedID
                photo.anchorVisible = route.anchorVisible ?? true
                photo.addedIDs = Set(route.addedIDs)
                photo.removedIDs = Set(route.removedIDs)
                photo.autoRouteIDs = Set(photo.cluster(containing: route.selectedID)?.holdIDs ?? [])
            }
        }
        return photo
    }

    static func makePaths(_ holds: [HoldInstance]) -> [Int: Path] {
        var result: [Int: Path] = [:]
        for hold in holds {
            let cgPath: CGPath = hold.contours.isEmpty
                ? CGPath(rect: hold.normalizedBounds, transform: nil)
                : ContourBuilder.path(for: hold.contours)
            result[hold.id] = Path(cgPath)
        }
        return result
    }
}

@MainActor
final class ClimbColorViewModel: ObservableObject {
    enum ModelState { case loading, ready, missing }
    enum Phase: Equatable { case idle, analyzing, ready, failed(String) }

    static let missingModelMessage =
        "The on-device model is missing from this build. Please reinstall or update the app."

    // Library (everything ever imported, persisted on disk)
    @Published private(set) var records: [WallRecord] = []
    @Published private(set) var isOpening = false
    let library = WallLibrary.shared

    // Open walls
    @Published private(set) var photos: [WallPhoto] = []
    @Published private(set) var currentID: UUID?
    /// Full-resolution original of the current photo (nil while loading).
    @Published private(set) var displayImage: UIImage?
    @Published private(set) var importingCount = 0
    /// true = Library on screen while walls stay open in the background.
    @Published var showingLibrary = true

    // Settings / UI state
    @Published private(set) var modelState: ModelState = .loading
    @Published var confidence: Double = 0.15
    @Published var isEditingRoute = false
    @Published var showDetection = true
    /// Which labels: 1 2 3 or A B C (never .off — on/off is `showLabels`).
    @Published var labelStyle: HoldLabelStyle = ClimbColorViewModel.storedLabelStyle() {
        didSet { UserDefaults.standard.set(labelStyle.rawValue, forKey: "holdLabelStyle") }
    }
    /// Labels on/off. Switchable right on the wall, remembered.
    @Published var showLabels: Bool = ClimbColorViewModel.storedShowLabels() {
        didSet { UserDefaults.standard.set(showLabels, forKey: "showHoldLabels") }
    }

    /// The home-screen choice: 1 2 3 / A B C / Off, kept in sync with the
    /// on/off switch on the wall.
    var labelChoice: HoldLabelStyle {
        get { showLabels ? labelStyle : .off }
        set {
            if newValue == .off {
                showLabels = false
            } else {
                labelStyle = newValue
                showLabels = true
            }
        }
    }

    func toggleLabels() {
        haptic.selectionChanged()
        showLabels.toggle()
    }

    nonisolated private static func storedLabelStyle() -> HoldLabelStyle {
        let raw = UserDefaults.standard.string(forKey: "holdLabelStyle") ?? ""
        let style = HoldLabelStyle(rawValue: raw) ?? .numbers
        return style == .off ? .numbers : style
    }

    nonisolated private static func storedShowLabels() -> Bool {
        if UserDefaults.standard.object(forKey: "showHoldLabels") == nil {
            // v8 stored "off" as a style; respect it.
            return UserDefaults.standard.string(forKey: "holdLabelStyle") != HoldLabelStyle.off.rawValue
        }
        return UserDefaults.standard.bool(forKey: "showHoldLabels")
    }
    @Published var history: [SavedAnalysis] = []
    @Published var toast: String?
    /// Hold ids currently being re-detected after a long-press.
    @Published private(set) var refiningHoldIDs: Set<Int> = []

    private let yolo = YOLOHoldDetector()
    private let colors = ColorAnalyzer()
    private let renderer = OverlayRenderer()
    private let store = ResultStore()
    private let haptic = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private var queueTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var routeSaveTask: Task<Void, Never>?
    private var resolvingPlaces = false
    private var placeAttempted: Set<UUID> = []
    private var modelBusy = false

    init() {
        history = store.load()
        records = library.loadIndex()
        PhotoFiles.clearSession()          // leftover temporary import copies only
        Task {
            let ok = await yolo.loadIfAvailable()
            modelState = ok ? .ready : .missing
            if ok { pumpQueue() }
        }
        resolvePlaces()
    }

    // MARK: - Current photo (read-only views for the UI)

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return photos.firstIndex { $0.id == currentID }
    }

    var current: WallPhoto? {
        guard let index = currentIndex else { return nil }
        return photos[index]
    }

    var hasPhotos: Bool { !photos.isEmpty }
    var image: UIImage? { displayImage ?? current?.thumbnail }
    var holds: [HoldInstance] { current?.holds ?? [] }
    var holdPaths: [Int: Path] { current?.holdPaths ?? [:] }
    var clusters: [ColorCluster] { current?.clusters ?? [] }
    var selectedID: Int? { current?.selectedID }
    var anchorID: Int? { current?.anchorID }
    var routeIDs: Set<Int> { current?.routeIDs ?? [] }

    var selectedCluster: ColorCluster? {
        guard let photo = current, let selected = photo.selectedID else { return nil }
        return photo.cluster(containing: selected)
    }

    var phase: Phase {
        guard let photo = current else { return .idle }
        switch photo.status {
        case .ready: return .ready
        case .analyzing: return .analyzing
        case .failed(let message): return .failed(message)
        case .pending:
            return modelState == .missing ? .failed(Self.missingModelMessage) : .analyzing
        }
    }

    var isAnalyzing: Bool { phase == .analyzing }
    var canEditHolds: Bool { phase == .ready }

    var positionText: String? {
        guard photos.count > 1, let index = currentIndex else { return nil }
        return "\(index + 1) / \(photos.count)"
    }

    var canStepBack: Bool { (currentIndex ?? 0) > 0 }
    var canStepForward: Bool {
        guard let index = currentIndex else { return false }
        return index < photos.count - 1
    }

    var routeName: String? { selectedCluster?.name }

    /// Labels for the holds of the route on screen, bottom → top.
    var routeLabels: [Int: String] {
        guard showLabels, let photo = current, photo.selectedID != nil else { return [:] }
        return HoldLabelStyle.labels(routeIDs: photo.routeIDs, holds: photo.holds, style: labelStyle)
    }

    var routeColor: Color? {
        guard let lab = selectedCluster?.lab else { return nil }
        let rgb = ColorAnalyzer.labToRGB(lab)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func updateCurrent(_ body: (inout WallPhoto) -> Void) {
        guard let index = currentIndex else { return }
        body(&photos[index])
    }

    private func update(_ id: UUID, _ body: (inout WallPhoto) -> Void) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        body(&photos[index])
    }

    // MARK: - Library records

    func record(for id: UUID) -> WallRecord? {
        records.first { $0.id == id }
    }

    private func updateRecord(_ id: UUID, _ body: (inout WallRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
    }

    private func persistIndex() {
        library.saveIndexAsync(records)
    }

    /// Opens walls from the library (saved analyses load instantly).
    func open(recordIDs: [UUID], focus: UUID?, route: SendRecord? = nil) {
        let chosen: [WallRecord] = recordIDs.compactMap { id in records.first { $0.id == id } }
        guard !chosen.isEmpty else { return }
        let library = self.library
        isOpening = true
        Task {
            let loaded: [WallPhoto] = await Task.detached(priority: .userInitiated) { () -> [WallPhoto] in
                chosen.map { WallPhoto.load(record: $0, library: library) }
            }.value
            isOpening = false
            displayTask?.cancel()
            photos = loaded
            currentID = nil
            displayImage = nil
            if let target = focus ?? loaded.first?.id {
                select(target)
            }
            if let route { applyRoute(route) }
            showingLibrary = false
            pumpQueue()
        }
    }

    func showLibrary() {
        isEditingRoute = false
        showingLibrary = true
    }

    func returnToWalls() {
        guard hasPhotos else { return }
        showingLibrary = false
    }

    func renamePlace(recordIDs: [UUID], to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for id in recordIDs {
            updateRecord(id) { $0.customPlaceName = trimmed.isEmpty ? nil : trimmed }
        }
        persistIndex()
    }

    func deleteFromLibrary(recordIDs: [UUID]) {
        let doomed = Set(recordIDs)
        for record in records where doomed.contains(record.id) {
            library.delete(record)
        }
        records.removeAll { doomed.contains($0.id) }
        persistIndex()

        let wasCurrent = currentID.map { doomed.contains($0) } ?? false
        let oldIndex = currentIndex ?? 0
        photos.removeAll { doomed.contains($0.id) }
        if wasCurrent {
            displayImage = nil
            currentID = nil
            if !photos.isEmpty {
                select(photos[min(oldIndex, photos.count - 1)].id)
            }
        }
        if photos.isEmpty { showingLibrary = true }
    }

    func deleteCurrentFromLibrary() {
        guard let id = currentID else { return }
        deleteFromLibrary(recordIDs: [id])
    }

    /// Names places from GPS (nearest climbing gym), one request at a time.
    private func resolvePlaces() {
        guard !resolvingPlaces else { return }
        resolvingPlaces = true
        Task {
            while let next = records.first(where: {
                $0.latitude != nil && $0.placeName == nil && !placeAttempted.contains($0.id)
            }) {
                placeAttempted.insert(next.id)
                guard let lat = next.latitude, let lon = next.longitude else { continue }
                guard let name = await PlaceResolver.name(latitude: lat, longitude: lon) else { continue }
                for index in records.indices where records[index].placeName == nil {
                    guard let la = records[index].latitude, let lo = records[index].longitude else { continue }
                    if PlaceResolver.distance(lat, lon, la, lo) < 150 {
                        records[index].placeName = name
                    }
                }
                persistIndex()
            }
            resolvingPlaces = false
        }
    }

    // MARK: - Adding photos

    /// Called the moment the picker closes, so the UI can show progress.
    func beginImport(count: Int) {
        importingCount += count
    }

    /// Moves picked files into the library and opens them. Photos already in
    /// the library reuse their saved analysis. Returns the opened ids.
    @discardableResult
    func importFiles(_ fileURLs: [URL], expected: Int, failed: Int,
                     latitude: Double? = nil, longitude: Double? = nil,
                     takenNow: Bool = false) async -> [UUID] {
        let library = self.library
        let known = records
        let captureDate: Date? = takenNow ? Date() : nil
        let outcome: WallLibrary.IngestOutcome = await Task.detached(priority: .userInitiated) {
            () -> WallLibrary.IngestOutcome in
            library.ingest(files: fileURLs, known: known,
                           latitude: latitude, longitude: longitude, captureDate: captureDate)
        }.value

        records.append(contentsOf: outcome.added)
        persistIndex()

        let opened: [WallRecord] = outcome.added + outcome.reused
        let loaded: [WallPhoto] = await Task.detached(priority: .userInitiated) { () -> [WallPhoto] in
            opened.map { WallPhoto.load(record: $0, library: library) }
        }.value
        importingCount = max(0, importingCount - expected)

        let unreadable = failed + outcome.failed
        guard let first = loaded.first else {
            toast = "Couldn't read the selected photos."
            return []
        }

        for photo in loaded where !photos.contains(where: { $0.id == photo.id }) {
            photos.append(photo)
        }
        displayImage = nil
        currentID = nil
        select(first.id)
        showingLibrary = false

        var parts: [String] = []
        if !outcome.added.isEmpty { parts.append("Added \(outcome.added.count)") }
        if !outcome.reused.isEmpty { parts.append("\(outcome.reused.count) already in Library") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        if loaded.count > 1 || !outcome.reused.isEmpty || unreadable > 0 {
            toast = parts.joined(separator: " · ")
        }

        pumpQueue()
        resolvePlaces()
        return loaded.map { $0.id }
    }

    func addCameraImage(_ image: UIImage) {
        beginImport(count: 1)
        Task {
            let url: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
                let upright = image.normalizedForProcessing()
                guard let data = upright.jpegData(compressionQuality: 0.95) else { return nil }
                return try? PhotoFiles.store(data, ext: "jpg")
            }.value
            guard let url else {
                importingCount = max(0, importingCount - 1)
                toast = "Couldn't save the photo."
                return
            }
            let ids = await importFiles([url], expected: 1, failed: 0, takenNow: true)

            // Tag in-app photos with where they were taken (asks once).
            guard let id = ids.first, let location = await LocationGrabber.shared.currentLocation() else { return }
            updateRecord(id) {
                if $0.latitude == nil {
                    $0.latitude = location.coordinate.latitude
                    $0.longitude = location.coordinate.longitude
                }
            }
            persistIndex()
            resolvePlaces()
        }
    }

    // MARK: - Navigation between walls

    func select(_ id: UUID) {
        guard id != currentID || displayImage == nil else { return }
        currentID = id
        isEditingRoute = false
        recomputeAutoRoute()
        loadDisplayImage()
    }

    func step(by delta: Int) {
        guard let index = currentIndex else { return }
        let target = index + delta
        guard photos.indices.contains(target) else { return }
        haptic.selectionChanged()
        select(photos[target].id)
    }

    /// Closes the photo in the viewer. It stays in the library.
    func closeCurrentPhoto() {
        guard let index = currentIndex else { return }
        photos.remove(at: index)
        displayImage = nil
        currentID = nil
        if photos.isEmpty {
            showingLibrary = true
        } else {
            select(photos[min(index, photos.count - 1)].id)
        }
    }

    /// Closes every open wall and returns to the library. Nothing is deleted.
    func closeAllWalls() {
        displayTask?.cancel()
        photos = []
        currentID = nil
        displayImage = nil
        isEditingRoute = false
        showingLibrary = true
    }

    private func loadDisplayImage() {
        displayTask?.cancel()
        displayImage = nil
        guard let photo = current else { return }
        let url = photo.fileURL
        let id = photo.id
        displayTask = Task {
            let full: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                PhotoFiles.image(at: url, maxPixel: nil)   // original resolution
            }.value
            guard !Task.isCancelled, currentID == id else { return }
            displayImage = full
        }
    }

    // MARK: - Detection queue (one photo at a time, current photo first)

    private func pumpQueue() {
        guard queueTask == nil, modelState == .ready else { return }
        queueTask = Task {
            while let id = nextPendingID() {
                await analyze(photoID: id)
            }
            queueTask = nil
        }
    }

    private func nextPendingID() -> UUID? {
        if let photo = current, photo.status == .pending { return photo.id }
        return photos.first(where: { $0.status == .pending })?.id
    }

    private func analyze(photoID: UUID) async {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return }
        update(photoID) { $0.status = .analyzing }

        let url = photo.fileURL
        let detector = yolo
        let analyzer = colors
        let threshold = confidence

        let analysisImage: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            PhotoFiles.image(at: url, maxPixel: 2048)
        }.value
        guard let analysisImage else {
            update(photoID) { $0.status = .failed("Couldn't open this photo.") }
            return
        }

        // Wait for any long-press re-detection to finish: one model, one job.
        while modelBusy {
            try? await Task.sleep(for: .milliseconds(80))
        }
        modelBusy = true
        defer { modelBusy = false }
        do {
            let raw = try await detector.detect(image: analysisImage, confidence: threshold)
            let colored: [HoldInstance] = await Task.detached(priority: .userInitiated) { () -> [HoldInstance] in
                analyzer.attachColors(to: raw.holds, image: analysisImage)
            }.value

            update(photoID) {
                $0.setHolds(colored)
                $0.analysisConfidence = threshold
                $0.selectedID = nil
                $0.autoRouteIDs = []
                $0.addedIDs = []
                $0.removedIDs = []
                $0.status = .ready
            }
            saveAnalysis(photoID: photoID)
            updateRecord(photoID) {
                $0.analyzedAt = Date()
                $0.analysisConfidence = threshold
                $0.route = nil
            }
            persistIndex()
        } catch {
            update(photoID) { $0.status = .failed(error.localizedDescription) }
        }
    }

    /// Writes the current holds (detected + hand-added) to the library so
    /// this wall never has to be detected again.
    private func saveAnalysis(photoID: UUID) {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return }
        let file = AnalysisFile(confidence: photo.analysisConfidence, createdAt: Date(),
                                holds: photo.holds.map { HoldRecord(hold: $0) })
        library.saveAnalysisAsync(file, for: photoID)
        updateRecord(photoID) { $0.holdCount = photo.holds.count }
        persistIndex()
    }

    func redetectCurrent() {
        guard modelState == .ready, let photo = current, photo.status != .analyzing else { return }
        isEditingRoute = false
        updateCurrent {
            $0.status = .pending
            $0.setHolds([])
            $0.selectedID = nil
        }
        pumpQueue()
    }

    func setSensitivity(_ value: Double) {
        confidence = value
        redetectCurrent()
    }

    // MARK: - Routes: color buttons and taps

    /// A color button: show every hold of that color (tap again to clear).
    func selectCluster(_ clusterID: Int) {
        haptic.selectionChanged()
        guard let cluster = clusters.first(where: { $0.id == clusterID }),
              let first = cluster.holdIDs.first else { return }
        if selectedCluster?.id == clusterID {
            clearRoute()
            return
        }
        isEditingRoute = false
        updateCurrent {
            $0.selectedID = first
            $0.anchorVisible = false
            $0.addedIDs = []
            $0.removedIDs = []
        }
        recomputeAutoRoute()
    }

    /// Tapping a hold shows its color group; in Edit mode it adds/removes it.
    func tapHold(_ id: Int) {
        haptic.selectionChanged()
        guard let photo = current else { return }

        if isEditingRoute, photo.selectedID != nil {
            toggleMembership(id)
            return
        }
        if photo.selectedID == id, photo.anchorVisible {
            clearRoute()
            return
        }
        updateCurrent {
            $0.selectedID = id
            $0.anchorVisible = true
            $0.addedIDs = []
            $0.removedIDs = []
        }
        recomputeAutoRoute()
    }

    func clearRoute() {
        isEditingRoute = false
        updateCurrent {
            $0.selectedID = nil
            $0.autoRouteIDs = []
            $0.addedIDs = []
            $0.removedIDs = []
        }
        saveRouteSoon()
    }

    private func toggleMembership(_ id: Int) {
        let inRoute = routeIDs.contains(id)
        updateCurrent { photo in
            if inRoute {
                if id == photo.selectedID {
                    // Removing the anchor: move it to another hold of the route.
                    let others = photo.routeIDs.subtracting([id])
                    guard let replacement = others.sorted().first else { return }
                    photo.selectedID = replacement
                    photo.anchorVisible = false
                }
                if photo.addedIDs.contains(id) { photo.addedIDs.remove(id) } else { photo.removedIDs.insert(id) }
            } else {
                if photo.removedIDs.contains(id) { photo.removedIDs.remove(id) } else { photo.addedIDs.insert(id) }
            }
        }
        saveRouteSoon()
    }

    private func recomputeAutoRoute() {
        guard let photo = current else { return }
        guard let selected = photo.selectedID else {
            saveRouteSoon()
            return
        }
        let ids: Set<Int> = Set(photo.cluster(containing: selected)?.holdIDs ?? [selected])
        updateCurrent { $0.autoRouteIDs = ids }
        saveRouteSoon()
    }

    /// Remembers the route on this wall (debounced) so it reopens as left.
    private func saveRouteSoon() {
        guard let photo = current else { return }
        var state: RouteState?
        if let selected = photo.selectedID {
            state = RouteState(selectedID: selected,
                               addedIDs: photo.addedIDs.sorted(),
                               removedIDs: photo.removedIDs.sorted(),
                               tolerance: 0,
                               colorHex: routeColorHex,
                               holdCount: photo.routeIDs.count,
                               colorName: routeName,
                               anchorVisible: photo.anchorVisible)
        }
        let id = photo.id
        guard record(for: id)?.route != state else { return }
        updateRecord(id) { $0.route = state }
        routeSaveTask?.cancel()
        routeSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persistIndex()
        }
    }

    private var routeColorHex: String? {
        guard let lab = selectedCluster?.lab else { return nil }
        let rgb = ColorAnalyzer.labToRGB(lab)
        let r = Int((rgb.r * 255).rounded())
        let g = Int((rgb.g * 255).rounded())
        let b = Int((rgb.b * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Sends (completed routes)

    /// The send matching the route on screen (same color, mostly same holds).
    var currentRouteSend: SendRecord? {
        guard let id = currentID, let name = routeName,
              let sends = record(for: id)?.sends else { return nil }
        let route = routeIDs
        return sends.first { send in
            guard send.colorName == name else { return false }
            let overlap = Set(send.holdIDs).intersection(route).count
            return overlap * 2 >= min(send.holdIDs.count, route.count)
        }
    }

    /// Color names already sent on this wall (✓ on the color buttons).
    var sentColorNames: Set<String> {
        guard let id = currentID, let sends = record(for: id)?.sends else { return [] }
        return Set(sends.map { $0.colorName })
    }

    func toggleSent() {
        guard let id = currentID, let name = routeName else { return }
        if let existing = currentRouteSend {
            updateRecord(id) { record in
                record.sends?.removeAll { $0.id == existing.id }
                if record.sends?.isEmpty == true { record.sends = nil }
            }
            toast = "Send removed"
        } else {
            let send = SendRecord(id: UUID(), date: Date(), colorName: name,
                                  colorHex: routeColorHex, holdIDs: routeIDs.sorted())
            updateRecord(id) { record in
                var list: [SendRecord] = record.sends ?? []
                list.append(send)
                record.sends = list
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            toast = "Sent! \(name) · \(send.holdIDs.count) holds"
        }
        persistIndex()
    }

    struct SendEntry: Identifiable {
        let send: SendRecord
        let record: WallRecord
        var id: UUID { send.id }
    }

    /// Every completed route, newest first (the climbing log).
    var allSends: [SendEntry] {
        var entries: [SendEntry] = []
        for record in records {
            for send in record.sends ?? [] {
                entries.append(SendEntry(send: send, record: record))
            }
        }
        return entries.sorted { $0.send.date > $1.send.date }
    }

    func openSend(_ entry: SendEntry) {
        open(recordIDs: [entry.record.id], focus: entry.record.id, route: entry.send)
    }

    func removeSend(_ entry: SendEntry) {
        updateRecord(entry.record.id) { record in
            record.sends?.removeAll { $0.id == entry.send.id }
            if record.sends?.isEmpty == true { record.sends = nil }
        }
        persistIndex()
    }

    /// Shows exactly the holds of a saved send.
    private func applyRoute(_ send: SendRecord) {
        guard let photo = current, photo.status == .ready else { return }
        let existing: Set<Int> = Set(photo.holds.map { $0.id })
        let wanted: Set<Int> = Set(send.holdIDs).intersection(existing)
        guard let anchor = wanted.sorted().first else { return }
        let group: Set<Int> = Set(photo.cluster(containing: anchor)?.holdIDs ?? [anchor])
        updateCurrent {
            $0.selectedID = anchor
            $0.anchorVisible = false
            $0.autoRouteIDs = group
            $0.addedIDs = wanted.subtracting(group)
            $0.removedIDs = group.subtracting(wanted)
        }
        saveRouteSoon()
    }

    // MARK: - Adding / removing holds by hand

    /// Long-press on empty wall: a circle appears at once, then the model
    /// re-runs on a close-up crop and replaces the circle with the real
    /// outline if it finds a hold there. Saved to the library either way.
    func addManualHold(at center: CGPoint, radiusPixels: CGFloat) {
        guard let photo = current, photo.status == .ready else { return }
        let photoID = photo.id
        let newID = (photo.holds.map { $0.id }.max() ?? -1) + 1
        guard let circle = ManualHoldFactory.circle(id: newID, center: center,
                                                    radiusPixels: radiusPixels,
                                                    pixelSize: photo.pixelSize) else { return }
        impact.impactOccurred()

        let routeActive = photo.selectedID != nil
        update(photoID) {
            $0.setHolds($0.holds + [circle])
            if routeActive { $0.addedIDs.insert(newID) }   // "this route is missing a hold"
        }
        refiningHoldIDs.insert(newID)
        saveAnalysis(photoID: photoID)
        if routeActive { saveRouteSoon() }

        Task {
            await refineManualHold(holdID: newID, photoID: photoID,
                                   center: center, radiusPixels: radiusPixels)
            refiningHoldIDs.remove(newID)
        }
    }

    private func refineManualHold(holdID: Int, photoID: UUID, center: CGPoint, radiusPixels: CGFloat) async {
        guard let photo = photos.first(where: { $0.id == photoID }) else { return }
        let pixelSize = photo.pixelSize
        let url = photo.fileURL
        let source: UIImage? = (photoID == currentID) ? displayImage : nil
        let analyzer = colors

        // A close-up around the press: small footholds become large for the model.
        let side = min(max(radiusPixels * 8, 384), max(pixelSize.width, pixelSize.height))
        let crop = CGRect(x: center.x * pixelSize.width - side / 2,
                          y: center.y * pixelSize.height - side / 2,
                          width: side, height: side)
            .intersection(CGRect(origin: .zero, size: pixelSize))
            .integral
        guard crop.width >= 32, crop.height >= 32 else { return }
        let local = CGPoint(x: (center.x * pixelSize.width - crop.minX) / crop.width,
                            y: (center.y * pixelSize.height - crop.minY) / crop.height)
        let localRadius = radiusPixels

        let prepared: (image: UIImage, circleLab: LabColor?)? = await Task.detached(priority: .userInitiated) {
            () -> (image: UIImage, circleLab: LabColor?)? in
            guard
                let full = source ?? PhotoFiles.image(at: url, maxPixel: nil),
                let cg = full.cgImage,
                let piece = cg.cropping(to: crop)
            else { return nil }
            let cropImage = UIImage(cgImage: piece)
            var lab: LabColor?
            if let probe = ManualHoldFactory.circle(id: 0, center: local, radiusPixels: localRadius,
                                                     pixelSize: crop.size) {
                lab = analyzer.attachColors(to: [probe], image: cropImage).first?.lab
            }
            return (image: cropImage, circleLab: lab)
        }.value
        guard let prepared else { return }

        // The circle gets its measured color right away.
        update(photoID) { photo in
            var holds = photo.holds
            if let index = holds.firstIndex(where: { $0.id == holdID }) {
                holds[index].lab = prepared.circleLab
                photo.setHolds(holds)
            }
        }

        // Re-detect on the close-up, unless the model is busy with a whole photo.
        var refined: HoldInstance?
        if modelState == .ready, !modelBusy {
            modelBusy = true
            let result = try? await yolo.detect(image: prepared.image, confidence: 0.10)
            modelBusy = false
            if let found = result?.holds
                .filter({ $0.mask.contains(normalized: local) })
                .min(by: { $0.mask.pixelCount < $1.mask.pixelCount }) {
                let colored: HoldInstance? = await Task.detached(priority: .userInitiated) { () -> HoldInstance? in
                    analyzer.attachColors(to: [found], image: prepared.image).first
                }.value
                let cropRect = CGRect(x: crop.minX / pixelSize.width, y: crop.minY / pixelSize.height,
                                      width: crop.width / pixelSize.width, height: crop.height / pixelSize.height)
                refined = ManualHoldFactory.remap(found, id: holdID, cropRect: cropRect,
                                                  pixelSize: pixelSize,
                                                  lab: colored?.lab ?? prepared.circleLab)
            }
        }

        if let refined {
            update(photoID) { photo in
                var holds = photo.holds
                if let index = holds.firstIndex(where: { $0.id == holdID }) {
                    holds[index] = refined
                    photo.setHolds(holds)
                }
            }
            toast = "Hold outlined"
        } else {
            toast = "Hold added"
        }
        if photoID == currentID { recomputeAutoRoute() }
        saveAnalysis(photoID: photoID)
    }

    /// Long-press on a hold: remove it (false detections, volumes, bolts…).
    func removeHold(_ id: Int) {
        guard let photo = current else { return }
        let photoID = photo.id
        impact.impactOccurred()
        update(photoID) { photo in
            photo.setHolds(photo.holds.filter { $0.id != id })
            photo.addedIDs.remove(id)
            photo.removedIDs.remove(id)
            if photo.selectedID == id {
                let others = photo.routeIDs.subtracting([id])
                if let replacement = others.sorted().first {
                    photo.selectedID = replacement
                    photo.anchorVisible = false
                } else {
                    photo.selectedID = nil
                    photo.autoRouteIDs = []
                }
            }
        }
        recomputeAutoRoute()
        saveAnalysis(photoID: photoID)
        toast = "Hold removed"
    }

    // MARK: - Saving and sharing

    private var caption: String {
        if let name = routeName { return "\(name) · \(routeIDs.count) holds" }
        return "\(holds.count) holds"
    }

    /// Renders the current photo + outlines. `maxPixel == nil` = original resolution.
    private func renderComposite(maxPixel: Int?) async -> UIImage? {
        guard let photo = current, !photo.holds.isEmpty else { return nil }
        let url = photo.fileURL
        let holds = photo.holds
        let anchor = photo.anchorID
        let route = photo.routeIDs
        let labels = self.routeLabels
        let text = self.caption
        let painter = self.renderer
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let base = PhotoFiles.image(at: url, maxPixel: maxPixel) else { return nil }
            return painter.composite(original: base, holds: holds, selectedID: anchor,
                                     routeIDs: route, caption: text, labels: labels)
        }.value
    }

    /// Image for the share sheet (send the route to a friend).
    func imageForSharing() async -> UIImage? {
        await renderComposite(maxPixel: 3072)
    }

    func saveCompositeToPhotos() {
        Task {
            guard let composite = await renderComposite(maxPixel: nil) else { return }
            do {
                try await PhotoLibrarySaver.save(composite)
                toast = "Saved to Photos"
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    func saveLayerToPhotos(routeOnly: Bool) {
        guard let photo = current, !photo.holds.isEmpty else { return }
        let size = photo.pixelSize
        let holds = photo.holds
        let anchor = photo.anchorID
        let route = photo.routeIDs
        let labels = self.routeLabels
        let painter = self.renderer
        Task {
            let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
                painter.layerPNG(size: size, holds: holds, selectedID: anchor,
                                 routeIDs: route, content: routeOnly ? .routeOnly : .all,
                                 labels: labels)
            }.value
            guard let data else { return }
            do {
                try await PhotoLibrarySaver.savePNG(
                    data, filename: routeOnly ? "ClimbColorRoute.png" : "ClimbColorLayer.png")
                toast = routeOnly ? "Route layer saved" : "Detection layer saved"
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    // MARK: - Older exports

    func image(for item: SavedAnalysis) -> UIImage? { store.image(for: item) }

    func deleteHistory(at offsets: IndexSet) {
        for item in offsets.map({ history[$0] }) { try? store.delete(item) }
        history.remove(atOffsets: offsets)
    }
}

struct RootView: View {
    var body: some View {
        WallWorkspaceView()
    }
}

#Preview {
    RootView().environmentObject(ClimbColorViewModel())
}
