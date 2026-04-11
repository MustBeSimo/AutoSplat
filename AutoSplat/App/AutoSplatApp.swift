import SwiftUI
import os

let logger = Logger(subsystem: "com.autosplat.app", category: "main")

func appLog(_ message: String) {
    logger.notice("\(message)")
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoSplat/debug.log")
    let line = "\(Date()): \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
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
