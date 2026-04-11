import SwiftUI
import UniformTypeIdentifiers

struct BatchConversionSheet: View {
    @EnvironmentObject var modelRunner: SHARPModelRunner
    @ObservedObject var batchProcessor: BatchProcessor
    @Environment(\.dismiss) private var dismiss

    @State private var inputURLs: [URL] = []
    @State private var outputFolder: URL?
    @State private var collisionOption: CollisionOption = .skip
    @State private var showStopConfirm = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Batch Conversion")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(Theme.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Input files
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionHeader("Input Files")
                HStack {
                    Text("\(inputURLs.count) files selected")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    GhostButton(title: "Select", icon: "folder") {
                        selectInputFiles()
                    }
                }
            }

            // Output folder
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionHeader("Output Folder")
                HStack {
                    Text(outputFolder?.lastPathComponent ?? "Not selected")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    GhostButton(title: "Select", icon: "folder.badge.plus") {
                        selectOutputFolder()
                    }
                }
            }

            // Collision
            if !inputURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Theme.sectionHeader("If File Exists")
                    HStack(spacing: 4) {
                        ForEach(CollisionOption.allCases) { option in
                            Button {
                                collisionOption = option
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(collisionOption == option ? Theme.accentCyan : Theme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(collisionOption == option ? Theme.accentCyan.opacity(0.15) : .clear)
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    collisionOption == option ? Theme.accentCyan.opacity(0.4) : Theme.borderSubtle,
                                                    lineWidth: 1
                                                )
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider().overlay(Theme.borderSubtle)

            // Progress
            if batchProcessor.state == .processing || batchProcessor.state == .stopping {
                VStack(spacing: 8) {
                    CyanProgressBar(value: batchProcessor.progress)
                    Text(batchProcessor.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(batchProcessor.currentFileIndex) / \(batchProcessor.totalFiles)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if batchProcessor.state == .completed {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.success)
                    Text("Completed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.success)
                }
                if let folder = outputFolder {
                    GhostButton(title: "Reveal in Finder", icon: "folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    }
                }
            }

            // Actions
            HStack {
                GhostButton(title: "Cancel", icon: nil) {
                    if batchProcessor.state == .processing {
                        showStopConfirm = true
                    } else {
                        dismiss()
                    }
                }
                Spacer()
                if batchProcessor.state == .processing || batchProcessor.state == .stopping {
                    GhostButton(title: "Stop", icon: "stop.fill", accent: Theme.error) {
                        showStopConfirm = true
                    }
                } else if batchProcessor.state != .completed {
                    GradientPillButton(
                        title: "Start",
                        icon: "play.fill",
                        isDisabled: inputURLs.isEmpty || outputFolder == nil || !modelRunner.isModelLoaded
                    ) {
                        startBatch()
                    }
                } else {
                    GradientPillButton(title: "Done", icon: nil) { dismiss() }
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.bgSecondary)
        .preferredColorScheme(.dark)
        .alert("Stop Processing?", isPresented: $showStopConfirm) {
            Button("Continue", role: .cancel) {}
            Button("Stop", role: .destructive) { batchProcessor.stop() }
        } message: {
            Text("Are you sure you want to stop the current batch?")
        }
    }

    private func selectInputFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .heic, .image]
        if panel.runModal() == .OK {
            var urls: [URL] = []
            let fm = FileManager.default
            let imageExtensions = Set(["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic"])
            for url in panel.urls {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        urls.append(contentsOf: contents.filter { imageExtensions.contains($0.pathExtension.lowercased()) })
                    }
                } else {
                    urls.append(url)
                }
            }
            inputURLs = urls
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    private func startBatch() {
        guard let output = outputFolder else { return }
        Task {
            await batchProcessor.process(inputURLs: inputURLs, outputFolder: output, collisionOption: collisionOption)
        }
    }
}
