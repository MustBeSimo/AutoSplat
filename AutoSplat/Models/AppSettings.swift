import SwiftUI
import Combine
import UniformTypeIdentifiers

enum ViewMode: Int, Codable {
    case image2D = 0
    case webView3D = 1
}

enum StereoMode: Int, CaseIterable, Identifiable {
    case mono = -1
    case sideBySide = 0
    case overUnder = 1
    case anaglyphRedBlue = 2
    case anaglyphGreenMagenta = 3
    case anaglyphCustom = 4
    case parallaxBarrier = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .mono: return "Single View"
        case .sideBySide: return "Side by Side"
        case .overUnder: return "Over / Under"
        case .anaglyphRedBlue: return NSLocalizedString("stereo_color_anaglyph", comment: "Color Anaglyph")
        case .anaglyphGreenMagenta: return NSLocalizedString("stereo_gray_anaglyph", comment: "Gray Anaglyph")
        case .anaglyphCustom: return "Custom Anaglyph"
        case .parallaxBarrier: return "Parallax Barrier"
        }
    }
}

class AppSettings: ObservableObject {
    @Published var viewMode: ViewMode = .image2D
    @Published var isSharpMode: Bool = true
    @Published var isShowingHelp: Bool = false
    @Published var isShowingBatchSheet: Bool = false
    @Published var isShowingPLYPreview: Bool = false
    @Published var isControlPanelExpanded: Bool = true
    @Published var isHeadTrackingEnabled: Bool = false
    @Published var headTrackSensitivity: Double = 50  // 0-100

    // Viewer controls
    @Published var stereoType: StereoMode = .mono
    @Published var swapLR: Bool = false
    @Published var depth: Double = 50
    @Published var focus: Double = 50
    @Published var disparityFactor: Double = 1.0

    // File state
    @Published var inputImageURL: URL?
    @Published var inputURLs: [URL] = []
    @Published var outputPLYURL: URL?
    @Published var modelPath: URL?

    // Signals
    @Published var reloadSignal: Bool = false
    @Published var saveImageSignal: Bool = false

    static let appSupportDir: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AutoSplat")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var modelDirectory: URL {
        appSupportDir.appendingPathComponent("Models")
    }

    var isModelDownloaded: Bool {
        findModelURL() != nil
    }

    /// Searches for a CoreML model in AutoSplat and MLSharp app support directories
    func findModelURL() -> URL? {
        let fm = FileManager.default
        let searchDirs = [
            Self.modelDirectory,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MLSharp/Models")
        ]

        for dir in searchDirs {
            if let url = findModelIn(directory: dir) {
                return url
            }
        }
        return nil
    }

    private func findModelIn(directory: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            print("findModelIn: directory not found: \(directory.path)")
            return nil
        }
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            print("findModelIn: cannot list directory: \(directory.path)")
            return nil
        }
        print("findModelIn: \(directory.lastPathComponent) contains: \(contents.map { $0.lastPathComponent })")

        // Check for compiled model first (fastest)
        if let mlmodelc = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
            return mlmodelc
        }
        // Check for .mlpackage — but verify weights exist (not just the spec)
        if let mlpackage = contents.first(where: { $0.pathExtension == "mlpackage" }) {
            let weightsPath = mlpackage
                .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            if fm.fileExists(atPath: weightsPath.path) {
                return mlpackage
            }
            // No weights — incomplete download, skip it
            print("AppSettings: Found \(mlpackage.lastPathComponent) but weights are missing")
        }
        // Check for bare .mlmodel
        if let mlmodel = contents.first(where: { $0.pathExtension == "mlmodel" }) {
            return mlmodel
        }
        return nil
    }

    func migrateIfNeeded() {
        let fm = FileManager.default
        // Try both legacy names
        for legacyName in ["MLSharp", "SHARP"] {
            let oldDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(legacyName)
            let newDir = Self.appSupportDir

            if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
                print("Migrating data from \(legacyName) to AutoSplat...")
                try? fm.copyItem(at: oldDir, to: newDir)
                return
            }
        }
    }
}
