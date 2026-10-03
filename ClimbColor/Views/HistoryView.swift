import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "No Saved Results",
                        systemImage: "photo.stack",
                        description: Text(
                            "Images saved by older versions of ClimbColor."
                        )
                    )
                } else {
                    List {
                        ForEach(model.history) { item in
                            NavigationLink {
                                SavedResultDetailView(item: item)
                            } label: {
                                SavedResultRow(item: item)
                            }
                        }
                        .onDelete { offsets in
                            model.deleteHistory(at: offsets)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Older Exports")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }
}

private struct SavedResultRow: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let item: SavedAnalysis

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = model.image(for: item) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 86, height: 70)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind)
                    .font(.headline)

                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(
                    item.createdAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SavedResultDetailView: View {
    @EnvironmentObject private var model: ClimbColorViewModel
    let item: SavedAnalysis

    @State private var saveMessage: String?
    @State private var image: UIImage?
    @State private var zoomCommand: ZoomCommand?

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                // Pinch / double-tap to zoom, like the main wall view.
                ZoomableImageView(
                    image: image,
                    pixelSize: CGSize(width: image.size.width * image.scale,
                                      height: image.size.height * image.scale),
                    command: $zoomCommand
                )
                .background(Color.black)

                Button {
                    Task {
                        do {
                            try await PhotoLibrarySaver.save(image)
                            saveMessage = "Saved to Photos."
                        } catch {
                            saveMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
        .task { image = model.image(for: item) }
        .navigationTitle(item.kind)
        .navigationBarTitleDisplayMode(.inline)
    }
}
