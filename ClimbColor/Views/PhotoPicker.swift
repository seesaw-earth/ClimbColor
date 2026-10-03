import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen PHPicker that accepts any number of photos (including none).
/// Originals are copied as-is (HEIC/JPEG, full resolution, no cropping).
/// No photo-library permission is needed.
struct PhotoPicker: UIViewControllerRepresentable {
    /// Called immediately when the user taps Add, with how many were picked
    /// (0 = cancelled). The picker can be dismissed right away.
    let onPicked: (Int) -> Void
    /// Called later, once every original has been copied.
    let onLoaded: (_ urls: [URL], _ failed: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onLoaded: onLoaded)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0            // 0 = no limit
        config.selection = .ordered          // numbered badges, keeps the user's order
        config.preferredAssetRepresentationMode = .current   // original file, no transcode
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    /// Thread-safe collector for the async file loads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [Int: URL] = [:]
        private var failed = 0

        func add(_ url: URL, at index: Int) {
            lock.lock(); urls[index] = url; lock.unlock()
        }

        func fail() {
            lock.lock(); failed += 1; lock.unlock()
        }

        func result() -> ([URL], Int) {
            lock.lock(); defer { lock.unlock() }
            let ordered = urls.keys.sorted().compactMap { urls[$0] }
            return (ordered, failed)
        }
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (Int) -> Void
        let onLoaded: ([URL], Int) -> Void

        init(onPicked: @escaping (Int) -> Void, onLoaded: @escaping ([URL], Int) -> Void) {
            self.onPicked = onPicked
            self.onLoaded = onLoaded
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPicked(results.count)
            guard !results.isEmpty else { return }

            let collector = Collector()
            let group = DispatchGroup()
            let providers: [NSItemProvider] = results.map { $0.itemProvider }
            let onLoaded = self.onLoaded

            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    // The temporary file is deleted when this block returns: copy now.
                    if let url, let copy = try? PhotoFiles.importCopy(of: url) {
                        collector.add(copy, at: index)
                    } else {
                        collector.fail()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                _ = providers   // keep providers alive until every load finishes
                let (urls, failed) = collector.result()
                onLoaded(urls, failed)
            }
        }
    }
}
