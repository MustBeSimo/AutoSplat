import Foundation
import AVFoundation
import Vision
import Combine
import AppKit
import CoreImage

class HeadTrackingManager: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var isFaceDetected = false
    @Published var faceOffset = CGPoint.zero  // -1...1
    @Published var cameraAuthorized: Bool? = nil
    @Published var previewImage: NSImage? = nil

    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.autosplat.headtracking", qos: .userInteractive)
    private let ciContext = CIContext()
    private var previewCounter = 0

    // Simple approach: track bounding box center relative to first-seen position
    private var firstCenter: CGPoint? = nil
    private var warmupFrames = 0
    private var smoothX: CGFloat = 0
    private var smoothY: CGFloat = 0

    func start() {
        guard !isTracking else { return }
        firstCenter = nil
        warmupFrames = 0
        smoothX = 0
        smoothY = 0

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async { self?.cameraAuthorized = granted }
            if granted {
                self?.sessionQueue.async { self?.setupAndStart() }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        DispatchQueue.main.async {
            self.isTracking = false
            self.isFaceDetected = false
            self.faceOffset = .zero
            self.previewImage = nil
        }
    }

    private func setupAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.unlockForConfiguration()
        } catch {}

        self.captureSession = session
        session.startRunning()
        DispatchQueue.main.async {
            self.isTracking = true
        }
    }
}

extension HeadTrackingManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let request = VNDetectFaceLandmarksRequest()

        do { try handler.perform([request]) } catch { return }

        guard let face = request.results?.first else {
            DispatchQueue.main.async { self.isFaceDetected = false }
            return
        }

        // Use bounding box center — simplest and most reliable signal
        let cx = face.boundingBox.midX
        let cy = face.boundingBox.midY

        // Warmup: use first 10 frames to establish center
        warmupFrames += 1
        if firstCenter == nil && warmupFrames > 10 {
            firstCenter = CGPoint(x: cx, y: cy)
        }

        guard let center = firstCenter else {
            DispatchQueue.main.async { self.isFaceDetected = true }
            updatePreview(pixelBuffer: pixelBuffer, face: face, cx: cx, cy: cy)
            return
        }

        // Raw offset from center, amplified heavily
        let rawX = -(cx - center.x) * 8.0  // mirror + amplify
        let rawY = (cy - center.y) * 8.0

        // EMA smoothing — alpha 0.25 for responsive tracking
        let alpha: CGFloat = 0.25
        smoothX = alpha * rawX + (1 - alpha) * smoothX
        smoothY = alpha * rawY + (1 - alpha) * smoothY

        // Clamp
        let outX = max(-1, min(1, smoothX))
        let outY = max(-1, min(1, smoothY))

        updatePreview(pixelBuffer: pixelBuffer, face: face, cx: cx, cy: cy)

        DispatchQueue.main.async {
            self.isFaceDetected = true
            self.faceOffset = CGPoint(x: outX, y: outY)
        }
    }

    private func updatePreview(pixelBuffer: CVPixelBuffer, face: VNFaceObservation, cx: CGFloat, cy: CGFloat) {
        previewCounter += 1
        guard previewCounter % 5 == 0 else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let mirrored = ciImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
        guard let cgImage = ciContext.createCGImage(mirrored, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return }

        let img = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let bbox = face.boundingBox

        // Face box
        ctx.setStrokeColor(NSColor(red: 0, green: 0.898, blue: 1, alpha: 0.5).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: bbox.minX * w, y: bbox.minY * h, width: bbox.width * w, height: bbox.height * h))

        // Landmarks
        if let lm = face.landmarks {
            ctx.setStrokeColor(NSColor(red: 0, green: 0.898, blue: 1, alpha: 0.4).cgColor)
            ctx.setLineWidth(1)
            for region in [lm.faceContour, lm.leftEye, lm.rightEye, lm.leftEyebrow, lm.rightEyebrow, lm.nose, lm.outerLips, lm.innerLips] {
                guard let r = region, r.pointCount > 1 else { continue }
                let pts = r.normalizedPoints.map { CGPoint(x: (bbox.minX + $0.x * bbox.width) * w, y: (bbox.minY + $0.y * bbox.height) * h) }
                ctx.beginPath()
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }

        // Current face center (green)
        ctx.setFillColor(NSColor(red: 0.024, green: 0.839, blue: 0.627, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx * w - 4, y: cy * h - 4, width: 8, height: 8))

        // Calibrated center (white cross)
        if let c = firstCenter {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            let px = c.x * w; let py = c.y * h
            ctx.move(to: CGPoint(x: px - 8, y: py)); ctx.addLine(to: CGPoint(x: px + 8, y: py))
            ctx.move(to: CGPoint(x: px, y: py - 8)); ctx.addLine(to: CGPoint(x: px, y: py + 8))
            ctx.strokePath()

            // Direction line
            ctx.setStrokeColor(NSColor(red: 0.024, green: 0.839, blue: 0.627, alpha: 0.3).cgColor)
            ctx.move(to: CGPoint(x: px, y: py))
            ctx.addLine(to: CGPoint(x: cx * w, y: cy * h))
            ctx.strokePath()
        }

        img.unlockFocus()
        DispatchQueue.main.async { self.previewImage = img }
    }
}
