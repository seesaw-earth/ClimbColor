import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoSaveError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow ClimbColor to add photos in Settings to save images."
        }
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage) async throws {
        try await authorize()
        try await perform {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Saves PNG bytes as-is so transparency survives.
    static func savePNG(_ data: Data, filename: String) async throws {
        try await authorize()
        try await perform {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            if #available(iOS 26.0, *) {
                options.contentType = .png
            } else {
                options.uniformTypeIdentifier = UTType.png.identifier
            }
            PHAssetCreationRequest.forAsset()
                .addResource(with: .photo, data: data, options: options)
        }
    }

    private static func authorize() async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else {
            throw PhotoSaveError.permissionDenied
        }
    }

    private static func perform(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
        }
    }
}
