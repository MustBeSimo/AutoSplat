import Foundation
import Combine

enum BatchState: String {
    case idle
    case checkingConflicts
    case scanning
    case processing
    case stopping
    case completed
    case cancelled
}

enum CollisionOption: String, CaseIterable, Identifiable {
    case overwrite
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overwrite: return "Overwrite"
        case .skip: return "Skip"
        }
    }
}

class BatchProcessor: ObservableObject {
    @Published var state: BatchState = .idle
    @Published var progress: Double = 0
    @Published var currentFileIndex: Int = 0
    @Published var totalFiles: Int = 0
    @Published var statusMessage: String = ""

    private var modelRunner: SHARPModelRunner?
    private let cancelLock = NSLock()
    private var _isCancelled = false
    private var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _isCancelled }
        set { cancelLock.lock(); _isCancelled = newValue; cancelLock.unlock() }
    }

    func configure(runner: SHARPModelRunner) {
        self.modelRunner = runner
    }

    func process(
        inputURLs: [URL],
        outputFolder: URL,
        collisionOption: CollisionOption
    ) async {
        guard let runner = modelRunner else { return }

        await MainActor.run {
            state = .scanning
            statusMessage = NSLocalizedString("batch_status_scanning", comment: "Scanning files...")
            totalFiles = inputURLs.count
            currentFileIndex = 0
            progress = 0
            isCancelled = false
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // Filter to image files
        let imageExtensions = Set(["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic"])
        let imageURLs = inputURLs.filter { imageExtensions.contains($0.pathExtension.lowercased()) }

        await MainActor.run {
            totalFiles = imageURLs.count
            state = .processing
            statusMessage = NSLocalizedString("batch_status_processing", comment: "Processing...")
        }

        for (index, url) in imageURLs.enumerated() {
            if isCancelled {
                await MainActor.run {
                    state = .cancelled
                    statusMessage = ""
                }
                return
            }

            await MainActor.run {
                currentFileIndex = index + 1
                progress = Double(index) / Double(max(imageURLs.count, 1))
                statusMessage = "\(NSLocalizedString("batch_status_processing", comment: "Processing")) \(url.lastPathComponent)"
            }

            let outputName = url.deletingPathExtension().lastPathComponent + ".ply"
            let outputURL = outputFolder.appendingPathComponent(outputName)

            if fm.fileExists(atPath: outputURL.path) {
                switch collisionOption {
                case .skip:
                    continue
                case .overwrite:
                    try? fm.removeItem(at: outputURL)
                }
            }

            do {
                let plyURL = try await runner.processImage(at: url)
                try? fm.moveItem(at: plyURL, to: outputURL)
            } catch {
                print("Error processing \(url.lastPathComponent): \(error)")
            }
        }

        await MainActor.run {
            state = .completed
            progress = 1.0
            statusMessage = NSLocalizedString("batch_status_completed", comment: "Completed")
        }
    }

    func stop() {
        isCancelled = true
        state = .stopping
        statusMessage = NSLocalizedString("batch_status_stopping", comment: "Stopping...")
    }
}
