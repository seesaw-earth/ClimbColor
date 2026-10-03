import Foundation
import UIKit

final class ResultStore {
    private let fileManager = FileManager.default

    private var rootURL: URL {
        let docs = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        return docs.appendingPathComponent(
            "ClimbColorResults",
            isDirectory: true
        )
    }

    private var imagesURL: URL {
        rootURL.appendingPathComponent(
            "Images",
            isDirectory: true
        )
    }

    private var metadataURL: URL {
        rootURL.appendingPathComponent("results.json")
    }

    init() {
        try? fileManager.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )
    }

    func load() -> [SavedAnalysis] {
        guard
            let data = try? Data(contentsOf: metadataURL),
            let decoded = try? JSONDecoder().decode(
                [SavedAnalysis].self,
                from: data
            )
        else {
            return []
        }

        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(
        image: UIImage,
        detectedCount: Int,
        matchedCount: Int?,
        kind: String
    ) throws -> SavedAnalysis {
        try fileManager.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let url = imagesURL.appendingPathComponent(filename)

        guard let data = image.jpegData(compressionQuality: 0.93) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: url, options: .atomic)

        let entry = SavedAnalysis(
            id: id,
            createdAt: Date(),
            imageFilename: filename,
            detectedCount: detectedCount,
            matchedCount: matchedCount,
            kind: kind
        )

        var all = load()
        all.insert(entry, at: 0)
        try persist(all)
        return entry
    }

    func image(for entry: SavedAnalysis) -> UIImage? {
        let url = imagesURL.appendingPathComponent(
            entry.imageFilename
        )
        return UIImage(contentsOfFile: url.path)
    }

    func delete(_ entry: SavedAnalysis) throws {
        let imageURL = imagesURL.appendingPathComponent(
            entry.imageFilename
        )
        try? fileManager.removeItem(at: imageURL)

        let remaining = load().filter { $0.id != entry.id }
        try persist(remaining)
    }

    private func persist(_ entries: [SavedAnalysis]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: metadataURL, options: .atomic)
    }
}
