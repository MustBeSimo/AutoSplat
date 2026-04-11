import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var downloader: ModelDownloader
    @EnvironmentObject var modelRunner: SHARPModelRunner
    @EnvironmentObject var headTracker: HeadTrackingManager

    @StateObject private var batchProcessor = BatchProcessor()
    @State private var isDragTargeted = false

    var body: some View {
        ZStack {
            // Layer 0: Full-bleed content
            mainCanvas
                .ignoresSafeArea()

            // Layer 1: Top status bar
            VStack {
                TopStatusBar()
                Spacer()
            }

            // Layer 2: Floating control panel (right side)
            HStack(spacing: 0) {
                Spacer()
                FloatingControlPanel(batchProcessor: batchProcessor)
                    .padding(Theme.panelInset)
            }

            // Layer 3: Head tracking overlays
            if settings.isHeadTrackingEnabled {
                // Direction arrow indicator (center of screen)
                DirectionArrow(offset: headTracker.faceOffset)
                    .allowsHitTesting(false)

                // PIP preview (bottom-left)
                if let preview = headTracker.previewImage {
                    VStack {
                        Spacer()
                        HStack {
                            Image(nsImage: preview)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Theme.accentCyan.opacity(0.2), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.4), radius: 6)
                                .padding(12)
                            Spacer()
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Theme.bgPrimary)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Theme.accentCyan.opacity(0.06))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $settings.isShowingBatchSheet) {
            BatchConversionSheet(batchProcessor: batchProcessor)
                .environmentObject(modelRunner)
        }
        .sheet(isPresented: $settings.isShowingHelp) {
            HelpView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .onAppear {
            batchProcessor.configure(runner: modelRunner)
            Task {
                appLog("onAppear: isModelDownloaded=\(settings.isModelDownloaded), isModelLoaded=\(modelRunner.isModelLoaded)")
                if settings.isModelDownloaded && !modelRunner.isModelLoaded {
                    do {
                        try await modelRunner.loadModel(settings: settings)
                    } catch {
                        appLog("Model load failed: \(error)")
                        await MainActor.run {
                            modelRunner.modelLoadingError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    // MARK: - Main Canvas

    @ViewBuilder
    private var mainCanvas: some View {
        switch settings.viewMode {
        case .image2D:
            DropZoneView(isDragTargeted: isDragTargeted, onOpenImage: {
                openFilePicker(types: [.png, .jpeg, .tiff, .bmp, .heic, .image])
            }, onOpen3D: {
                openFilePicker(types: [.data])
            }, inputImageURL: settings.inputImageURL,
               isProcessing: modelRunner.isProcessing,
               statusMessage: modelRunner.statusMessage,
               isModelLoaded: modelRunner.isModelLoaded,
               onGenerate: { generateSplat() }
            )
        case .webView3D:
            WebViewPreview(
                fileURL: settings.outputPLYURL,
                isSharpMode: settings.isSharpMode,
                stereoType: $settings.stereoType,
                swapLR: $settings.swapLR,
                depth: $settings.depth,
                focus: $settings.focus,
                reloadSignal: $settings.reloadSignal,
                saveImageSignal: $settings.saveImageSignal,
                headTracker: headTracker,
                isHeadTrackingEnabled: settings.isHeadTrackingEnabled,
                headTrackSensitivity: settings.headTrackSensitivity,
                onFileDrop: { url in handleFileURL(url) }
            )
            // Force updateNSView when sliders change
            .onChange(of: settings.depth) { _, _ in }
            .onChange(of: settings.focus) { _, _ in }
            .onChange(of: settings.headTrackSensitivity) { _, _ in }
        }
    }

    // MARK: - File Handling

    private func openFilePicker(types: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            appLog("FilePicker: selected \(url.lastPathComponent)")
            handleFileURL(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard error == nil else { return }
            var url: URL?
            if let urlData = item as? Data {
                url = URL(dataRepresentation: urlData, relativeTo: nil, isAbsolute: true)
            } else if let urlItem = item as? URL {
                url = urlItem
            }
            if let url = url {
                DispatchQueue.main.async { handleFileURL(url) }
            }
        }
        return true
    }

    private func handleFileURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Set(["ply", "splat", "ksplat", "spz"]).contains(ext) {
            settings.outputPLYURL = url
            settings.viewMode = .webView3D
        } else if Set(["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic"]).contains(ext) {
            settings.inputImageURL = url
            settings.viewMode = .image2D
        }
    }

    private func generateSplat() {
        guard let imageURL = settings.inputImageURL else { return }
        Task {
            do {
                let plyURL = try await modelRunner.processImage(at: imageURL, disparityFactor: Float(settings.disparityFactor))
                await MainActor.run {
                    settings.outputPLYURL = plyURL
                    settings.viewMode = .webView3D
                }
            } catch {
                appLog("Error processing image: \(error)")
            }
        }
    }
}

// MARK: - Drop Zone View

// MARK: - Brand Link

struct BrandLink: View {
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text("built by")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text("Simone")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Theme.accentCyan : Theme.accentCyan.opacity(0.7))
                .underline(isHovered)
        }
        .onTapGesture {
            if let url = URL(string: "https://www.w230.net") {
                NSWorkspace.shared.open(url)
            }
        }
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Direction Arrow Indicator

struct DirectionArrow: View {
    var offset: CGPoint  // -1...1

    @State private var pulseOpacity: Double = 0.6

    private var magnitude: Double {
        sqrt(offset.x * offset.x + offset.y * offset.y)
    }

    private var angle: Angle {
        // atan2 gives angle from positive X axis; we want arrow pointing in movement direction
        // offset.x positive = camera moving right, offset.y positive = camera moving up
        .radians(atan2(-Double(offset.x), Double(offset.y)))
    }

    var body: some View {
        let visible = magnitude > 0.03

        ZStack {
            // Outer glow ring
            Circle()
                .stroke(
                    RadialGradient(
                        colors: [Theme.accentCyan.opacity(0.15 * magnitude), .clear],
                        center: .center, startRadius: 20, endRadius: 50
                    ),
                    lineWidth: 1
                )
                .frame(width: 100, height: 100)

            // Arrow shape
            ArrowShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.accentCyan.opacity(0.9),
                            Theme.accentCyan.opacity(0.2)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 12, height: 36)
                .offset(y: -14)  // push arrow outward from center
                .rotationEffect(angle)

            // Center dot
            Circle()
                .fill(Theme.accentCyan.opacity(0.4 * pulseOpacity))
                .frame(width: 6, height: 6)
        }
        .opacity(visible ? min(magnitude * 3, 0.8) : 0)
        .animation(.easeInOut(duration: 0.6), value: visible)
        .animation(.easeInOut(duration: 0.3), value: offset.x)
        .animation(.easeInOut(duration: 0.3), value: offset.y)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseOpacity = 1.0
            }
        }
    }
}

struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Sleek chevron/arrow pointing up
        p.move(to: CGPoint(x: w * 0.5, y: 0))           // tip
        p.addLine(to: CGPoint(x: w, y: h * 0.35))        // right wing
        p.addLine(to: CGPoint(x: w * 0.65, y: h * 0.25)) // right notch
        p.addLine(to: CGPoint(x: w * 0.65, y: h))         // right tail
        p.addLine(to: CGPoint(x: w * 0.35, y: h))         // left tail
        p.addLine(to: CGPoint(x: w * 0.35, y: h * 0.25)) // left notch
        p.addLine(to: CGPoint(x: 0, y: h * 0.35))         // left wing
        p.closeSubpath()

        return p
    }
}

// MARK: - Drop Zone View

struct DropZoneView: View {
    var isDragTargeted: Bool
    var onOpenImage: () -> Void
    var onOpen3D: () -> Void
    var inputImageURL: URL?
    var isProcessing: Bool
    var statusMessage: String
    var isModelLoaded: Bool
    var onGenerate: () -> Void

    @State private var borderRotation: Double = 0
    @State private var iconOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Radial gradient background
            RadialGradient(
                colors: [Theme.bgTertiary.opacity(0.4), Theme.bgPrimary],
                center: .center,
                startRadius: 50, endRadius: 500
            )

            if let imageURL = inputImageURL, let nsImage = NSImage(contentsOf: imageURL) {
                // Image loaded — show preview + generate
                VStack(spacing: 20) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 500, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 20)

                    if isProcessing {
                        VStack(spacing: 12) {
                            CyanProgressBar(value: 0.5)
                                .frame(width: 200)
                            Text(statusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if isModelLoaded {
                        GradientPillButton(title: "Generate 3DGS", icon: "sparkles") {
                            onGenerate()
                        }
                    } else {
                        Text("Download the AI model first")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    GhostButton(title: "Choose Different Image", icon: "arrow.triangle.2.circlepath") {
                        onOpenImage()
                    }

                    BrandLink()
                        .padding(.top, 8)
                }
            } else {
                // Empty state — animated drop zone
                VStack(spacing: 24) {
                    // Animated border box
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(
                                AngularGradient(
                                    colors: [Theme.accentCyan, Theme.accentPurple, Theme.accentCyan],
                                    center: .center
                                ),
                                lineWidth: isDragTargeted ? 3 : 1.5
                            )
                            .frame(width: 240, height: 240)
                            .rotationEffect(.degrees(borderRotation))

                        VStack(spacing: 16) {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 56, weight: .thin))
                                .foregroundStyle(Theme.accentCyan)
                                .offset(y: iconOffset)

                            Text("Drop to Create")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)

                            Text("JPG  PNG  PLY  SPLAT  KSPLAT  SPZ")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .kerning(2)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        GhostButton(title: "Open Image", icon: "photo") {
                            onOpenImage()
                        }
                        GhostButton(title: "Open 3D File", icon: "cube") {
                            onOpen3D()
                        }
                    }

                    BrandLink()
                        .padding(.top, 4)
                }
                .onAppear {
                    withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                        borderRotation = 360
                    }
                    withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                        iconOffset = -8
                    }
                }
            }
        }
    }
}

// MARK: - Top Status Bar

struct TopStatusBar: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var modelRunner: SHARPModelRunner

    var body: some View {
        HStack(spacing: 12) {
            // Spacer for traffic lights
            Color.clear.frame(width: 70)

            // App title
            Text("AutoSplat")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if let file = settings.inputImageURL ?? settings.outputPLYURL {
                Text("—")
                    .foregroundStyle(Theme.textTertiary)
                Text(file.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            if modelRunner.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(modelRunner.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentCyan)
                }
            }

            Spacer()

            // Branding
            BrandLink()

            // Back to image mode button (when in 3D view)
            if settings.viewMode == .webView3D {
                GhostButton(title: "New", icon: "plus") {
                    settings.viewMode = .image2D
                    settings.inputImageURL = nil
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.ultraThinMaterial.opacity(0.5))
    }
}

// MARK: - Floating Control Panel

struct FloatingControlPanel: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var downloader: ModelDownloader
    @EnvironmentObject var modelRunner: SHARPModelRunner
    @EnvironmentObject var headTracker: HeadTrackingManager
    @ObservedObject var batchProcessor: BatchProcessor
    @State private var isModelLoading = false

    var body: some View {
        ZStack {
            if settings.isControlPanelExpanded {
                expandedPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                collapsedStrip
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.isControlPanelExpanded)
        .onAppear {
            if settings.isModelDownloaded && !modelRunner.isModelLoaded && !isModelLoading {
                loadModel()
            }
        }
    }

    // MARK: - Collapsed

    private var collapsedStrip: some View {
        VStack {
            Button {
                settings.isControlPanelExpanded = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.panelCollapsedWidth, height: Theme.panelCollapsedWidth)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(width: Theme.panelCollapsedWidth)
        .background(Theme.glass(cornerRadius: 12))
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Controls")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    settings.isControlPanelExpanded = false
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.bgTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider().overlay(Theme.borderSubtle)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Model Status
                    modelStatusSection

                    if settings.viewMode == .webView3D {
                        Divider().overlay(Theme.borderSubtle)
                        viewingModeSection
                        Divider().overlay(Theme.borderSubtle)
                        stereoSection
                        Divider().overlay(Theme.borderSubtle)
                        controlsSection
                    }

                    Divider().overlay(Theme.borderSubtle)
                    actionsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.glass())
    }

    // MARK: - Sections

    private func selectLocalModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select a CoreML model (.mlmodelc, .mlpackage, or .mlmodel)"

        if panel.runModal() == .OK, let url = panel.url {
            appLog("User selected model at: \(url.path)")
            // Copy/link to our model directory
            let fm = FileManager.default
            let destDir = AppSettings.modelDirectory
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            let destName = url.lastPathComponent
            let dest = destDir.appendingPathComponent(destName)
            try? fm.removeItem(at: dest)

            // Symlink to avoid copying multi-GB files
            try? fm.createSymbolicLink(at: dest, withDestinationURL: url)
            appLog("Linked model to: \(dest.path)")

            Task {
                do {
                    try await modelRunner.loadModel(settings: settings)
                } catch {
                    appLog("Model load from selection failed: \(error)")
                    await MainActor.run {
                        modelRunner.modelLoadingError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func loadModel() {
        isModelLoading = true
        Task {
            do {
                try await modelRunner.loadModel(settings: settings)
            } catch {
                appLog("loadModel failed: \(error)")
                await MainActor.run {
                    modelRunner.modelLoadingError = error.localizedDescription
                }
            }
            await MainActor.run { isModelLoading = false }
        }
    }

    private var modelStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader("AI Model")

            if modelRunner.isModelLoaded {
                HStack(spacing: 8) {
                    StatusDot(color: Theme.success)
                    Text("Model Ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.success)
                }
            } else if isModelLoading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Loading model...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accentCyan)
                    }
                }
            } else if downloader.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: Theme.accentCyan)
                        Text("Downloading...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accentCyan)
                    }
                    CyanProgressBar(value: downloader.progress)
                    Text(downloader.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            } else if modelRunner.modelLoadingError != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: Theme.warning)
                        Text("Load failed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.warning)
                    }
                    if let err = modelRunner.modelLoadingError {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                    GhostButton(title: "Retry", icon: "arrow.clockwise") {
                        loadModel()
                    }
                }
            } else {
                // Not downloaded / not found
                VStack(alignment: .leading, spacing: 8) {
                    GradientPillButton(title: "Download Model", icon: "arrow.down.circle") {
                        Task {
                            await downloader.downloadModel()
                            loadModel()
                        }
                    }
                    Text("~2.67 GB from Hugging Face")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)

                    GhostButton(title: "Select Local Model", icon: "folder") {
                        selectLocalModel()
                    }
                }
            }

            if let error = downloader.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.error)
                    .lineLimit(2)
            }
        }
    }

    private var viewingModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader("Viewing Mode")

            HStack(spacing: 4) {
                modeButton("SHARP", isActive: settings.isSharpMode) {
                    settings.isSharpMode = true
                }
                modeButton("General", isActive: !settings.isSharpMode) {
                    settings.isSharpMode = false
                }
            }
        }
    }

    private func modeButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accentCyan : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isActive ? Theme.accentCyan.opacity(0.15) : .clear)
                        .overlay(
                            Capsule().strokeBorder(isActive ? Theme.accentCyan.opacity(0.4) : Theme.borderSubtle, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var stereoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader("Stereo")

            // Picker styled as a glass dropdown
            Menu {
                ForEach(StereoMode.allCases) { mode in
                    Button(mode.label) { settings.stereoType = mode }
                }
            } label: {
                HStack {
                    Text(settings.stereoType.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.bgPrimary)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderSubtle, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)

            CyanToggle(isOn: $settings.swapLR, label: "Swap L/R")
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.sectionHeader("Controls")

            CyanSlider(value: $settings.depth, label: settings.stereoType == .mono ? "Distance" : "Depth")
            CyanSlider(value: $settings.focus, label: settings.stereoType == .mono ? "Zoom" : "Focus")

            // Head tracking
            HStack(spacing: 8) {
                CyanToggle(isOn: $settings.isHeadTrackingEnabled, label: "Head Track")
                if headTracker.isTracking && headTracker.isFaceDetected {
                    StatusDot(color: Theme.success)
                } else if headTracker.isTracking {
                    StatusDot(color: Theme.warning)
                }
            }
            .onChange(of: settings.isHeadTrackingEnabled) { _, enabled in
                if enabled {
                    headTracker.start()
                } else {
                    headTracker.stop()
                }
            }
            if settings.isHeadTrackingEnabled {
                CyanSlider(value: $settings.headTrackSensitivity, label: "Sensitivity")
            }
            if headTracker.cameraAuthorized == false {
                Text("Camera access denied")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.error)
            }
        }
    }

    @State private var isExporting = false
    @State private var exportStatus = ""

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader("Actions")

            HStack(spacing: 8) {
                GhostButton(title: "Reset", icon: "arrow.counterclockwise") {
                    settings.depth = 50
                    settings.focus = 50
                    settings.reloadSignal = true
                }
                if settings.viewMode == .webView3D {
                    GhostButton(title: "Save", icon: "square.and.arrow.down") {
                        settings.saveImageSignal = true
                    }
                }
            }

            // Export 3D
            if settings.viewMode == .webView3D, settings.outputPLYURL != nil {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text(exportStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accentCyan)
                    }
                } else {
                    GhostButton(title: "Export 3D", icon: "square.and.arrow.up") {
                        showExportPanel()
                    }
                }
            }

            GhostButton(title: "Batch Convert", icon: "square.on.square", accent: Theme.accentPurple) {
                settings.isShowingBatchSheet = true
            }

            GhostButton(title: "Help", icon: "questionmark.circle") {
                settings.isShowingHelp = true
            }
        }
    }

    private func showExportPanel() {
        guard let plyURL = settings.outputPLYURL else { return }

        let panel = NSSavePanel()
        panel.title = "Export 3D File"
        panel.nameFieldStringValue = plyURL.deletingPathExtension().lastPathComponent

        // Format picker as accessory view
        let formats = ExportFormat.allCases
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        for fmt in formats { picker.addItem(withTitle: fmt.rawValue) }
        picker.selectItem(at: 0)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 36))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 0, y: 6, width: 55, height: 20)
        label.font = .systemFont(ofSize: 12)
        picker.frame = NSRect(x: 58, y: 4, width: 180, height: 28)
        accessory.addSubview(label)
        accessory.addSubview(picker)
        panel.accessoryView = accessory

        // Update allowed types when picker changes
        func updateTypes() {
            let fmt = formats[picker.indexOfSelectedItem]
            panel.allowedContentTypes = [UTType(filenameExtension: fmt.fileExtension) ?? .data]
            panel.nameFieldStringValue = plyURL.deletingPathExtension().lastPathComponent + "." + fmt.fileExtension
        }
        updateTypes()

        // Observe picker changes
        picker.target = panel
        picker.action = nil  // We'll handle in the response

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        let format = formats[picker.indexOfSelectedItem]
        isExporting = true
        exportStatus = "Exporting \(format.rawValue)..."

        Task {
            do {
                try await SplatExporter.export(plyURL: plyURL, to: destURL, format: format)
                await MainActor.run {
                    isExporting = false
                    exportStatus = ""
                    // Reveal in Finder
                    NSWorkspace.shared.selectFile(destURL.path, inFileViewerRootedAtPath: destURL.deletingLastPathComponent().path)
                }
            } catch {
                appLog("Export error: \(error)")
                await MainActor.run {
                    isExporting = false
                    exportStatus = ""
                }
            }
        }
    }
}
