import SwiftUI
import WebKit
import Combine

// MARK: - JS String Escaping (Finding 4 fix)

private func escapeForJS(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "'", with: "\\'")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\r", with: "\\r")
}

// MARK: - Allowed directories for WebView file access

private func webViewAccessDirectories() -> [URL] {
    var dirs: [URL] = []
    if let resources = Bundle.main.resourceURL {
        dirs.append(resources)
    }
    // Staging dir for PLY files
    dirs.append(plyStagingDirectory())
    return dirs
}

private func plyStagingDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSplatViewer")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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

        // SECURITY: Enable file access for ES module imports (required for file:// CORS)
        // Only allowFileAccessFromFileURLs on preferences — NOT universal access on config
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // REMOVED: config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // JS console bridge
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "logHandler")
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

        // SECURITY: Load from bundle resources with access restricted to resources + staging dir
        if let htmlURL = Bundle.main.url(forResource: "gaus3d", withExtension: "html") {
            let resourcesDir = htmlURL.deletingLastPathComponent()
            appLog("WebView: Loading gaus3d.html (restricted to resources dir)")
            webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesDir)
        } else {
            appLog("WebView Error: gaus3d.html not found in bundle!")
        }

        context.coordinator.webView = webView
        context.coordinator.pendingFileURL = fileURL
        return webView
    }

    func updateNSView(_ webView: DroppableWebView, context: Context) {
        guard webView.isPageLoaded else { return }

        // Stereo type
        if context.coordinator.lastStereoType != stereoType.rawValue {
            context.coordinator.lastStereoType = stereoType.rawValue
            if stereoType == .mono {
                webView.safeEvaluateJS("SetMonoFromNative()")
            } else {
                webView.safeEvaluateJS("ChgstFromNative(\(stereoType.rawValue))")
            }
        }

        // Depth/focus (numeric values — no injection risk)
        if context.coordinator.lastDepth != depth || context.coordinator.lastFocus != focus {
            context.coordinator.lastDepth = depth
            context.coordinator.lastFocus = focus
            if stereoType == .mono {
                webView.safeEvaluateJS("SetCameraFromNative(\(depth), \(focus))")
            } else {
                webView.safeEvaluateJS("SetFocusFromNative(\(focus), \(depth))")
            }
        }

        // Swap (boolean — no injection risk)
        if context.coordinator.lastSwap != swapLR {
            context.coordinator.lastSwap = swapLR
            webView.safeEvaluateJS("SwapFromNative(\(swapLR))")
        }

        // Reload — uses escaped filename
        if reloadSignal {
            DispatchQueue.main.async { reloadSignal = false }
            if let fileURL = fileURL {
                let safeName = escapeForJS(fileURL.lastPathComponent)
                appLog("WebView: Reload with \(safeName)")
                // Stage file to temp dir and load via relative path
                context.coordinator.stageAndLoadFile(fileURL)
            }
        }

        // Save image
        if saveImageSignal {
            DispatchQueue.main.async { saveImageSignal = false }
            webView.safeEvaluateJS("saveImage()")
        }

        // Head tracking
        if isHeadTrackingEnabled, let tracker = headTracker {
            if context.coordinator.headTrackingCancellable == nil {
                context.coordinator.startHeadTracking(tracker: tracker)
            }
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

        // SECURITY: Stage PLY to temp dir (not app bundle) and load via XHR
        func stageAndLoadFile(_ fileURL: URL) {
            guard let webView = webView else { return }
            let stagingDir = plyStagingDirectory()
            let stagedName = "_current.ply"
            let stagedURL = stagingDir.appendingPathComponent(stagedName)
            let fm = FileManager.default

            do {
                try? fm.removeItem(at: stagedURL)
                try fm.copyItem(at: fileURL, to: stagedURL)
                appLog("WebView: Staged PLY to \(stagingDir.path)")
            } catch {
                appLog("WebView: Failed to stage PLY: \(error.localizedDescription)")
                return
            }

            // Load via absolute file URL (escaped)
            let safeURL = escapeForJS(stagedURL.absoluteString)
            let isMono = parent.stereoType == .mono
            webView.safeEvaluateJS("""
                (function waitAndLoad() {
                    if (typeof window.FileFromNative === 'function') {
                        console.log('FileFromNative ready, loading file...');
                        window.FileFromNative('\(safeURL)');
                        \(isMono ? "setTimeout(function(){ if(window.SetMonoFromNative) window.SetMonoFromNative(); }, 500);" : "")
                    } else {
                        setTimeout(waitAndLoad, 200);
                    }
                })();
            """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            appLog("WebView: didFinish loading")
            guard let droppable = webView as? DroppableWebView else { return }
            droppable.isPageLoaded = true

            // Load pending file
            if let fileURL = pendingFileURL ?? parent.fileURL {
                stageAndLoadFile(fileURL)
            }
            hasInitialized = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            appLog("WebView navigation error: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            appLog("WebView provisional error: \(error.localizedDescription)")
        }

        // SECURITY: Whitelist navigation to file:// only (Finding 5)
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.isFileURL {
                decisionHandler(.allow)
            } else if url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                // Open external URLs in browser instead
                appLog("WebView: Blocked navigation to \(url.scheme ?? "unknown")://... opening in browser")
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // MARK: - Head Tracking

        func startHeadTracking(tracker: HeadTrackingManager) {
            guard headTrackingCancellable == nil else { return }
            webView?.safeEvaluateJS("HeadTrackStartFromNative()")

            let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                guard let self = self, let webView = self.webView else { return }
                guard tracker.isTracking, tracker.isFaceDetected else { return }
                let o = tracker.faceOffset
                if abs(o.x) > 0.001 || abs(o.y) > 0.001 {
                    // Numeric values only — no injection risk
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
