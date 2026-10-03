import SwiftUI
import UIKit

/// Home screen: every wall you've photographed, organized the way climbers
/// think about them — by visit (date + gym), and by gym.
struct LibraryView: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onExports: () -> Void

    enum Mode: Hashable { case sessions, gyms, sends }

    @State private var mode: Mode = .sessions
    @State private var renameIDs: [UUID] = []
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleteIDs: [UUID] = []
    @State private var showDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if model.records.isEmpty {
                    emptyState
                } else {
                    libraryList
                }
            }
            .navigationTitle("ClimbColor")
            .toolbar {
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(action: onExports) {
                                Label("Older Exported Images", systemImage: "photo.stack")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
        .alert("Name this place", isPresented: $showRename) {
            TextField("e.g. Brooklyn Boulders", text: $renameText)
            Button("Save") { model.renamePlace(recordIDs: renameIDs, to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used to group your walls by gym.")
        }
        .confirmationDialog("Delete \(deleteIDs.count) photo\(deleteIDs.count == 1 ? "" : "s") from the library?",
                            isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteFromLibrary(recordIDs: deleteIDs) }
        } message: {
            Text("Photos in your Photos app are not affected.")
        }
    }

    // MARK: Lists

    private var libraryList: some View {
        List {
            Picker("View", selection: $mode) {
                Text("Sessions").tag(Mode.sessions)
                Text("Gyms").tag(Mode.gyms)
                Text("Sends").tag(Mode.sends)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            labelStyleRow

            if mode == .sessions {
                ForEach(LibraryOrganizer.sessions(model.records)) { session in
                    SessionRow(session: session, actions: rowActions)
                }
            } else if mode == .sends {
                sendsSection
            } else {
                ForEach(LibraryOrganizer.gyms(model.records)) { gym in
                    NavigationLink {
                        GymSessionsView(gym: gym, actions: rowActions)
                    } label: {
                        GymRow(gym: gym)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.isOpening {
                ProgressView().controlSize(.large)
            }
        }
    }

    /// How route holds are labeled on every wall (bottom → top).
    private var labelStyleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "number.circle.fill")
                    .foregroundStyle(Color(uiColor: HoldStyle.routeColor))
                Text("Route labels")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("bottom → top")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Route labels", selection: $model.labelChoice) {
                ForEach(HoldLabelStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 2)
    }

    /// The climbing log: every route marked Sent, newest first.
    @ViewBuilder
    private var sendsSection: some View {
        let entries = model.allSends
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No sends yet")
                    .font(.headline)
                Text("Open a wall, pick a route, and tap \u{201C}Sent?\u{201D} when you top it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(entries) { entry in
                    Button {
                        model.openSend(entry)
                    } label: {
                        SendRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            model.removeSend(entry)
                        } label: {
                            Label("Remove Send", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("\(entries.count) route\(entries.count == 1 ? "" : "s") sent")
            }
        }
    }

    private var rowActions: SessionRow.Actions {
        SessionRow.Actions(
            rename: { ids, current in
                renameIDs = ids
                renameText = current ?? ""
                showRename = true
            },
            delete: { ids in
                deleteIDs = ids
                showDelete = true
            }
        )
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "figure.climbing")
                .font(.system(size: 58))
                .foregroundStyle(Color(uiColor: HoldStyle.routeColor))
            Text("Photograph one wall or a whole session.\nTap one hold. See the whole route.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Your walls are kept here, grouped by visit and gym,\nso they open instantly next time.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: Add bar

    private var addBar: some View {
        VStack(spacing: 8) {
            if model.hasPhotos {
                // Walls stay open in the background: one tap goes back.
                Button {
                    model.returnToWalls()
                } label: {
                    HStack(spacing: 10) {
                        if let thumb = model.current?.thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Text(model.photos.count == 1
                             ? "Back to open wall"
                             : "Back to \(model.photos.count) open walls")
                            .font(.headline)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color(uiColor: HoldStyle.routeColor).opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button(action: onCamera) {
                    Label("Take Photo", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

                Button(action: onPhotos) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }

            if model.importingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Adding \(model.importingCount) photo\(model.importingCount == 1 ? "" : "s")…")
                        .font(.footnote)
                }
            } else if model.modelState == .missing {
                Text("The on-device model is missing from this build. Please reinstall or update the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Session row

struct SessionRow: View {
    struct Actions {
        let rename: (_ ids: [UUID], _ current: String?) -> Void
        let delete: (_ ids: [UUID]) -> Void
    }

    @EnvironmentObject private var model: ClimbColorViewModel
    let session: WallSession
    let actions: Actions

    private var ids: [UUID] { session.records.map { $0.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.place ?? LibraryOrganizer.unknownPlace)
                        .font(.headline)
                        .foregroundStyle(session.place == nil ? Color.secondary : Color.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        model.open(recordIDs: ids, focus: nil)
                    } label: {
                        Label("Open All", systemImage: "rectangle.stack")
                    }
                    Button {
                        actions.rename(ids, session.place)
                    } label: {
                        Label("Name This Place…", systemImage: "mappin.and.ellipse")
                    }
                    Button(role: .destructive) {
                        actions.delete(ids)
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .padding(.leading, 8)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.records) { record in
                        Button {
                            model.open(recordIDs: ids, focus: record.id)
                        } label: {
                            WallThumbnail(record: record)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                                Button(role: .destructive) {
                                    actions.delete([record.id])
                                } label: {
                                    Label("Delete Photo", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let calendar = Calendar.current
        let sameYear = calendar.isDate(session.start, equalTo: Date(), toGranularity: .year)
        let date: String = sameYear
            ? session.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : session.start.formatted(.dateTime.month(.abbreviated).day().year())
        let walls = session.records.count
        var text = "\(date) · \(walls) wall\(walls == 1 ? "" : "s")"
        if session.sendCount > 0 {
            text += " · \(session.sendCount) sent"
        } else if session.routeCount > 0 {
            text += " · \(session.routeCount) route\(session.routeCount == 1 ? "" : "s")"
        }
        return text
    }
}

/// Square preview with the saved route's color (if any) and hold count.
struct WallThumbnail: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let record: WallRecord
    var size: CGFloat = 84

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.library.thumbnail(for: record.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()      // preview only; the wall itself is never cropped
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 4) {
                if record.sendCount > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                }
                if let hex = record.route?.colorHex {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                if let count = record.holdCount {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(record.holdCount == nil && record.route == nil && record.sendCount == 0 ? 0 : 0.5),
                        in: Capsule())
            .padding(5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(record.route == nil ? "Wall photo" : "Wall photo with saved route")
    }
}

// MARK: - Gyms

struct GymRow: View {
    let gym: GymSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: gym.name == LibraryOrganizer.unknownPlace ? "questionmark.circle" : "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(Color(uiColor: HoldStyle.routeColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let walls = gym.records.count
        let visits = gym.sessionCount
        let last = gym.lastVisit.formatted(.dateTime.month(.abbreviated).day())
        return "\(walls) wall\(walls == 1 ? "" : "s") · \(visits) visit\(visits == 1 ? "" : "s") · last \(last)"
    }
}

struct GymSessionsView: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let gym: GymSummary
    let actions: SessionRow.Actions

    var body: some View {
        // Re-read from the model so renames and deletions show up immediately.
        let ids = Set(gym.records.map { $0.id })
        let current = model.records.filter { ids.contains($0.id) }
        List {
            ForEach(LibraryOrganizer.sessions(current)) { session in
                SessionRow(session: session, actions: actions)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(gym.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Sends

struct SendRow: View {
    let entry: ClimbColorViewModel.SendEntry

    var body: some View {
        HStack(spacing: 12) {
            WallThumbnail(record: entry.record, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let hex = entry.send.colorHex {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                    }
                    Text("\(entry.send.colorName) · \(entry.send.holdIDs.count) holds")
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let place = entry.record.displayPlace ?? LibraryOrganizer.unknownPlace
        let date = entry.send.date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(place) · \(date)"
    }
}
