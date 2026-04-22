import SwiftUI
import os

let logger = Logger(subsystem: "com.autosplat.app", category: "main")

private let maxLogSize: UInt64 = 10 * 1024 * 1024  // 10 MB

func appLog(_ message: String) {
    logger.notice("\(message)")
    #if DEBUG
    let fm = FileManager.default
    let logFile = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoSplat/debug.log")
    let line = "\(Date()): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if fm.fileExists(atPath: logFile.path) {
        // Rotate if too large
        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > maxLogSize {
            try? fm.removeItem(at: logFile)
            try? data.write(to: logFile, options: [.atomic])
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    } else {
        // Create with restricted permissions (owner read/write only)
        fm.createFile(atPath: logFile.path, contents: data,
                      attributes: [.posixPermissions: 0o600])
    }
    #endif
}

@main
struct AutoSplatApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var downloader = ModelDownloader()
    @StateObject private var modelRunner = SHARPModelRunner()
    @StateObject private var headTracker = HeadTrackingManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(downloader)
                .environmentObject(modelRunner)
                .environmentObject(headTracker)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    configureWindow()
                    settings.migrateIfNeeded()
                    appLog("App launched. isModelDownloaded=\(settings.isModelDownloaded)")
                    if let url = settings.findModelURL() {
                        appLog("Model URL: \(url.path)")
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("AutoSplat Help") {
                    settings.isShowingHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Help", id: "help") {
            HelpView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 700, minHeight: 500)
        }
    }

    private func configureWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1)
            window.isMovableByWindowBackground = true
        }
    }
}
