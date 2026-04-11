import SwiftUI
import WebKit
import Combine

// MARK: - Droppable WKWebView

class DroppableWebView: WKWebView {
    var onFileDrop: ((URL) -> Void)?
    var isPageLoaded = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    func safeEvaluateJS(_ js: String) {
        guard isPageLoaded else { return }
        evaluateJavaScript(js) { _, error in
            if let error = error {
                appLog("JS Error: \(error.localizedDescription) — for: \(js.prefix(80))")
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let validExtensions = Set(["ply", "splat", "ksplat", "spz"])
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let valid = urls.contains { validExtensions.contains($0.pathExtension.lowercased()) }
            return valid ? .copy : []
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let firstURL = urls.first else {
            return false
        }
        onFileDrop?(firstURL)
        return true
    }
}

// MARK: - SwiftUI NSViewRepresentable

struct WebViewPreview: NSViewRepresentable {
    let fileURL: URL?
    let isSharpMode: Bool
    @Binding var stereoType: StereoMode
    @Binding var swapLR: Bool
    @Binding var depth: Double
    @Binding var focus: Double
    @Binding var reloadSignal: Bool
    @Binding var saveImageSignal: Bool
    var headTracker: HeadTrackingManager?
    var isHeadTrackingEnabled: Bool = false
    var headTrackSensitivity: Double = 50
    var onFileDrop: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DroppableWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Enable file access for ES modules (required for file:// CORS)
        // These are private keys — setValue:forKey: works on the correct objects
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        appLog("WebView: Enabled file access flags")

        // Add JS console logging bridge
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "logHandler")
        // Inject script to capture console.log/error and forward to native
        let consoleScript = WKUserScript(source: """
            (function() {
                var origLog = console.log;
                var origError = console.error;
                var origWarn = console.warn;
                console.log = function() {
                    origLog.apply(console, arguments);
                    window.webkit.messageHandlers.logHandler.postMessage('LOG: ' + Array.from(arguments).join(' '));
                };
                console.error = function() {
                    origError.apply(console, arguments);
                    window.webkit.messageHandlers.logHandler.postMessage('ERROR: ' + Array.from(arguments).join(' '));
                };
                console.warn = function() {
                    origWarn.apply(console, arguments);
                    window.webkit.messageHandlers.logHandler.postMessage('WARN: ' + Array.from(arguments).join(' '));
                };
                window.onerror = function(msg, url, line, col, error) {
                    window.webkit.messageHandlers.logHandler.postMessage('UNCAUGHT: ' + msg + ' at ' + url + ':' + line);
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(consoleScript)

        let webView = DroppableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.onFileDrop = { url in
            onFileDrop?(url)
        }

        // Load the viewer HTML via loadFileURL (required for ES module imports to work).
        // Since loadFileURL doesn't support query params, we write a modified copy
        // of gaus3d.html to a temp dir (alongside symlinks to the JS files) with
        // params baked into the source.
        if let htmlURL = Bundle.main.url(forResource: "gaus3d", withExtension: "html"),
           var htmlString = try? String(contentsOf: htmlURL, encoding: .utf8) {
            let mode = isSharpMode ? "sharp" : "general"
            let resourcesDir = htmlURL.deletingLastPathComponent()

            // Patch the line that reads URL params to inject our values
            var searchParams = "?mode=\(mode)"
            if let fileURL = fileURL {
                searchParams += "&openFile=\(fileURL.absoluteString)"
            }
            htmlString = htmlString.replacingOccurrences(
                of: "let Param = self.location.search;",
                with: "let Param = '\(searchParams)';"
            )

            // Load the ORIGINAL gaus3d.html from bundle (ES modules require proper origin).
            // We can't inject params, so we pass the file via JS after load.
            appLog("WebView: Loading original gaus3d.html (mode=\(mode), file=\(fileURL?.lastPathComponent ?? "none"))")
            webView.loadFileURL(htmlURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            appLog("WebView Error: gaus3d.html not found in bundle!")
        }

        context.coordinator.webView = webView
        context.coordinator.pendingFileURL = fileURL
        return webView
    }

    func updateNSView(_ webView: DroppableWebView, context: Context) {
        guard webView.isPageLoaded else { return }

        // Handle stereo type changes
        if context.coordinator.lastStereoType != stereoType.rawValue {
            context.coordinator.lastStereoType = stereoType.rawValue
            if stereoType == .mono {
                webView.safeEvaluateJS("SetMonoFromNative()")
            } else {
                webView.safeEvaluateJS("ChgstFromNative(\(stereoType.rawValue))")
            }
        }

        // Handle depth/focus
        if context.coordinator.lastDepth != depth || context.coordinator.lastFocus != focus {
            context.coordinator.lastDepth = depth
            context.coordinator.lastFocus = focus
            if stereoType == .mono {
                // Mono: depth = camera distance, focus = FOV zoom
                webView.safeEvaluateJS("SetCameraFromNative(\(depth), \(focus))")
            } else {
                // Stereo: depth = eye separation, focus = convergence
                webView.safeEvaluateJS("SetFocusFromNative(\(focus), \(depth))")
            }
        }

        // Handle swap changes
        if context.coordinator.lastSwap != swapLR {
            context.coordinator.lastSwap = swapLR
            webView.safeEvaluateJS("SwapFromNative(\(swapLR))")
        }

        // Handle reload signal
        if reloadSignal {
            DispatchQueue.main.async { reloadSignal = false }
            if let fileURL = fileURL {
                appLog("WebView: Reload signal with file \(fileURL.lastPathComponent)")
                webView.safeEvaluateJS("window.FileFromNative && window.FileFromNative('\(fileURL.absoluteString)')")
            }
        }

        // Handle save image signal
        if saveImageSignal {
            DispatchQueue.main.async { saveImageSignal = false }
            webView.safeEvaluateJS("saveImage()")
        }

        // Handle head tracking
        if isHeadTrackingEnabled, let tracker = headTracker {
            if context.coordinator.headTrackingCancellable == nil {
                context.coordinator.startHeadTracking(tracker: tracker)
            }
            // Update sensitivity in JS (0-100 → 0.2-3.0)
            let sens = 0.2 + (headTrackSensitivity / 100.0) * 2.8
            webView.safeEvaluateJS("HeadTrackSetSensitivity(\(sens))")
        } else if !isHeadTrackingEnabled {
            context.coordinator.stopHeadTracking()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                appLog("JS: \(body)")
            }
        }

        var parent: WebViewPreview
        weak var webView: DroppableWebView?
        var lastStereoType: Int = -99
        var lastSwap: Bool = false
        var lastDepth: Double = -1
        var lastFocus: Double = -1
        var pendingFileURL: URL?
        var hasInitialized = false
        var headTrackingCancellable: AnyCancellable?

        init(_ parent: WebViewPreview) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            appLog("WebView: didFinish loading")
            guard let droppable = webView as? DroppableWebView else { return }
            droppable.isPageLoaded = true

            // Set mode first
            let mode = parent.isSharpMode ? "sharp" : "general"
            let initJS = """
            if (typeof window.bsharp !== 'undefined') { window.bsharp = \(parent.isSharpMode); }
            """
            droppable.safeEvaluateJS(initJS)

            // Copy PLY to bundle Resources dir so it's accessible via relative URL
            if let fileURL = pendingFileURL ?? parent.fileURL {
                let resourcesDir = Bundle.main.resourceURL!
                let localName = "_current.ply"
                let localURL = resourcesDir.appendingPathComponent(localName)
                let fm = FileManager.default
                try? fm.removeItem(at: localURL)
                try? fm.copyItem(at: fileURL, to: localURL)

                appLog("WebView: Copied PLY to bundle, loading via relative URL")
                let isMono = parent.stereoType == .mono
                droppable.safeEvaluateJS("""
                    (function waitAndLoad() {
                        if (typeof window.FileFromNative === 'function') {
                            console.log('FileFromNative ready, loading file...');
                            window.FileFromNative('./\(localName)');
                            \(isMono ? "setTimeout(function(){ if(window.SetMonoFromNative) window.SetMonoFromNative(); }, 500);" : "")
                        } else {
                            setTimeout(waitAndLoad, 200);
                        }
                    })();
                """)
            }
            hasInitialized = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            appLog("WebView navigation error: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            appLog("WebView provisional error: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        // MARK: - Head Tracking

        func startHeadTracking(tracker: HeadTrackingManager) {
            guard headTrackingCancellable == nil else { return }
            webView?.safeEvaluateJS("HeadTrackStartFromNative()")

            // Use a Timer — most reliable way to poll at consistent rate
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                guard let self = self, let webView = self.webView else { return }
                guard tracker.isTracking, tracker.isFaceDetected else { return }
                let o = tracker.faceOffset
                // Only send if there's actual movement
                if abs(o.x) > 0.001 || abs(o.y) > 0.001 {
                    webView.safeEvaluateJS("HeadTrackMoveFromNative(\(o.x),\(o.y))")
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            headTrackingCancellable = AnyCancellable { timer.invalidate() }
        }

        func stopHeadTracking() {
            headTrackingCancellable?.cancel()
            headTrackingCancellable = nil
            webView?.safeEvaluateJS("HeadTrackStopFromNative()")
        }
    }
}
