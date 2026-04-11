import Foundation
import CoreML
import CoreImage
import CoreGraphics
import AppKit
import Combine

enum SHARPError: Error, LocalizedError {
    case modelNotLoaded
    case imageLoadFailed
    case imageResizeFailed
    case contextCreationFailed
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Model not loaded"
        case .imageLoadFailed: return "Failed to load image"
        case .imageResizeFailed: return "Failed to resize image"
        case .contextCreationFailed: return "Failed to create graphics context"
        case .predictionFailed(let msg): return "Prediction failed: \(msg)"
        }
    }
}

class SHARPModelRunner: ObservableObject {
    @Published var isProcessing = false
    @Published var statusMessage = ""
    @Published var modelLoadingError: String?

    private var model: MLModel?

    var isModelLoaded: Bool { model != nil }

    func loadModel(settings: AppSettings? = nil) async throws {
        // First check for pre-compiled .mlmodelc
        let s: AppSettings
        if let settings = settings {
            s = settings
        } else {
            s = await MainActor.run { AppSettings() }
        }
        guard let modelURL = s.findModelURL() else {
            throw SHARPError.modelNotLoaded
        }

        appLog("SHARPModelRunner: Found model at \(modelURL.path)")

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let loadedModel: MLModel

        if modelURL.pathExtension == "mlmodelc" {
            // Already compiled — load directly
            appLog("SHARPModelRunner: Loading compiled model")
            loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
        } else {
            // .mlpackage or .mlmodel — needs compilation
            appLog("SHARPModelRunner: Compiling model...")
            let compiledURL = try await MLModel.compileModel(at: modelURL)
            appLog("SHARPModelRunner: Compiled to \(compiledURL.path)")

            // Cache the compiled model for next time
            let cachedURL = AppSettings.modelDirectory.appendingPathComponent("sharp.mlmodelc")
            if !FileManager.default.fileExists(atPath: cachedURL.path) {
                try? FileManager.default.copyItem(at: compiledURL, to: cachedURL)
                appLog("SHARPModelRunner: Cached compiled model")
            }

            loadedModel = try MLModel(contentsOf: compiledURL, configuration: config)
        }

        // Log I/O
        let desc = loadedModel.modelDescription
        appLog("SHARPModelRunner: Inputs: \(desc.inputDescriptionsByName.keys.sorted().description)")
        appLog("SHARPModelRunner: Outputs: \(desc.outputDescriptionsByName.keys.sorted().description)")

        await MainActor.run {
            self.model = loadedModel
            self.modelLoadingError = nil
            appLog("SHARPModelRunner: Model loaded and ready")
        }
    }

    func processImage(at imageURL: URL, disparityFactor: Float = 1.0) async throws -> URL {
        guard let model = model else {
            throw SHARPError.modelNotLoaded
        }

        await MainActor.run {
            isProcessing = true
            statusMessage = NSLocalizedString("msg_preprocessing_image", comment: "Preprocessing image...")
        }

        // Load source image
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            await MainActor.run { isProcessing = false }
            throw SHARPError.imageLoadFailed
        }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        await MainActor.run {
            statusMessage = NSLocalizedString("msg_correcting_aspect", comment: "Correcting aspect ratio...")
        }

        // Model expects [1, 3, 1536, 1536]
        let inputSize = 1536
        let resized = try resizeImage(cgImage, to: CGSize(width: inputSize, height: inputSize))

        // Convert to MLMultiArray [1, 3, H, W]
        let imageArray = try imageToMultiArray(resized, width: inputSize, height: inputSize)

        // Disparity factor input [1]
        let dispArray = try MLMultiArray(shape: [1], dataType: .float32)
        dispArray[0] = NSNumber(value: disparityFactor)

        await MainActor.run {
            statusMessage = NSLocalizedString("msg_running_inference", comment: "Running inference...")
        }

        NSLog("SHARPModelRunner: Running prediction (1536x1536, disparity_factor=%.2f)...", disparityFactor)

        let featureProvider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: imageArray),
            "disparity_factor": MLFeatureValue(multiArray: dispArray)
        ])

        let prediction = try await model.prediction(from: featureProvider)

        appLog("SHARPModelRunner: Prediction complete, generating PLY...")

        await MainActor.run {
            statusMessage = "Generating 3DGS file..."
        }

        // Extract outputs
        guard let positionsArray = prediction.featureValue(for: "mean_vectors_3d_positions")?.multiArrayValue,
              let rotationsArray = prediction.featureValue(for: "quaternions_rotations")?.multiArrayValue,
              let scalesArray = prediction.featureValue(for: "singular_values_scales")?.multiArrayValue,
              let colorsArray = prediction.featureValue(for: "colors_rgb_linear")?.multiArrayValue,
              let opacitiesArray = prediction.featureValue(for: "opacities_alpha_channel")?.multiArrayValue else {
            await MainActor.run { isProcessing = false }
            throw SHARPError.predictionFailed("Missing output arrays")
        }

        // Generate PLY
        let outputURL = try generatePLY(
            positions: positionsArray,
            rotations: rotationsArray,
            scales: scalesArray,
            colors: colorsArray,
            opacities: opacitiesArray,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            imageURL: imageURL
        )

        await MainActor.run {
            isProcessing = false
            statusMessage = ""
        }

        appLog("SHARPModelRunner: PLY saved to \(outputURL.path)")
        return outputURL
    }

    // MARK: - Image Processing

    private func resizeImage(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = Int(size.width)
        let h = Int(size.height)
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SHARPError.contextCreationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let resized = context.makeImage() else {
            throw SHARPError.imageResizeFailed
        }
        return resized
    }

    private func imageToMultiArray(_ image: CGImage, width: Int, height: Int) throws -> MLMultiArray {
        let multiArray = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SHARPError.contextCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw SHARPError.contextCreationFailed }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: 3 * height * width)
        let planeSize = height * width
        for y in 0..<height {
            for x in 0..<width {
                let pixIdx = (y * width + x) * 4
                // Normalize to [0, 1]
                ptr[0 * planeSize + y * width + x] = Float(pixels[pixIdx]) / 255.0     // R
                ptr[1 * planeSize + y * width + x] = Float(pixels[pixIdx + 1]) / 255.0 // G
                ptr[2 * planeSize + y * width + x] = Float(pixels[pixIdx + 2]) / 255.0 // B
            }
        }

        return multiArray
    }

    // MARK: - PLY Generation

    private func generatePLY(
        positions: MLMultiArray,
        rotations: MLMultiArray,
        scales: MLMultiArray,
        colors: MLMultiArray,
        opacities: MLMultiArray,
        originalWidth: Int,
        originalHeight: Int,
        imageURL: URL
    ) throws -> URL {
        // Shape: [1, N, 3] for positions/rotations/scales/colors, [1, N] for opacities
        let numSplats = positions.shape[1].intValue
        appLog("SHARPModelRunner: Generating PLY with \(numSplats) splats")

        let posPtr = positions.dataPointer.bindMemory(to: Float.self, capacity: numSplats * 3)
        let rotPtr = rotations.dataPointer.bindMemory(to: Float.self, capacity: numSplats * 4)
        let scalePtr = scales.dataPointer.bindMemory(to: Float.self, capacity: numSplats * 3)
        let colorPtr = colors.dataPointer.bindMemory(to: Float.self, capacity: numSplats * 3)
        let opacityPtr = opacities.dataPointer.bindMemory(to: Float.self, capacity: numSplats)

        let fx = Float(originalWidth) * 0.7
        let fy = fx
        let cx = Float(originalWidth) / 2.0
        let cy = Float(originalHeight) / 2.0

        // PLY header — matches exact format from test.ply in the SHARP repo
        // IMPORTANT: vertex element FIRST, then metadata. No leading whitespace.
        let header = [
            "ply",
            "format binary_little_endian 1.0",
            "element vertex \(numSplats)",
            "property float x",
            "property float y",
            "property float z",
            "property float f_dc_0",
            "property float f_dc_1",
            "property float f_dc_2",
            "property float opacity",
            "property float scale_0",
            "property float scale_1",
            "property float scale_2",
            "property float rot_0",
            "property float rot_1",
            "property float rot_2",
            "property float rot_3",
            "element extrinsic 16",
            "property float extrinsic",
            "element intrinsic 9",
            "property float intrinsic",
            "element image_size 2",
            "property uint image_size",
            "element frame 2",
            "property int frame",
            "element disparity 2",
            "property float disparity",
            "element color_space 1",
            "property uchar color_space",
            "element version 3",
            "property uchar version",
            "end_header",
            ""  // final newline
        ].joined(separator: "\n")

        var plyData = Data()
        plyData.reserveCapacity(header.utf8.count + numSplats * 15 * 4 + 200)
        plyData.append(header.data(using: .ascii)!)

        // Write vertex data FIRST (scale before rot to match header order)
        let c0inv: Float = 1.0 / 0.28209479

        // Linear to sRGB conversion (reduces saturation since viewer applies gamma)
        func linearToSRGB(_ c: Float) -> Float {
            let clamped = min(max(c, 0), 1)
            return clamped <= 0.0031308
                ? clamped * 12.92
                : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }

        for i in 0..<numSplats {
            let px = posPtr[i * 3 + 0]
            let py = posPtr[i * 3 + 1]
            let pz = posPtr[i * 3 + 2]

            // Model outputs linear RGB — convert to sRGB before SH encoding
            // since the viewer's gammaOutput will apply an additional gamma curve
            let r = linearToSRGB(colorPtr[i * 3 + 0])
            let g = linearToSRGB(colorPtr[i * 3 + 1])
            let b = linearToSRGB(colorPtr[i * 3 + 2])
            let fdc0 = (r - 0.5) * c0inv
            let fdc1 = (g - 0.5) * c0inv
            let fdc2 = (b - 0.5) * c0inv

            let alpha = min(max(opacityPtr[i], 1e-6), 1.0 - 1e-6)
            let logitOpacity = log(alpha / (1.0 - alpha))

            let s0 = log(max(abs(scalePtr[i * 3 + 0]), 1e-8))
            let s1 = log(max(abs(scalePtr[i * 3 + 1]), 1e-8))
            let s2 = log(max(abs(scalePtr[i * 3 + 2]), 1e-8))

            let rw = rotPtr[i * 4 + 0]
            let rx = rotPtr[i * 4 + 1]
            let ry = rotPtr[i * 4 + 2]
            let rz = rotPtr[i * 4 + 3]

            // Order: x y z f_dc_0..2 opacity scale_0..2 rot_0..3 (matches header)
            var vertex: [Float] = [px, py, pz, fdc0, fdc1, fdc2, logitOpacity, s0, s1, s2, rw, rx, ry, rz]
            plyData.append(Data(bytes: &vertex, count: vertex.count * 4))
        }

        // Write metadata elements AFTER vertices
        // Extrinsic 4x4 identity (16 floats)
        appendFloats(&plyData, [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
        // Intrinsic 3x3 (9 floats)
        appendFloats(&plyData, [fx, 0, cx, 0, fy, cy, 0, 0, 1])
        // Image size (2 uint32)
        appendUInt32s(&plyData, [UInt32(originalWidth), UInt32(originalHeight)])
        // Frame (2 int32)
        appendInt32s(&plyData, [Int32(originalWidth), Int32(originalHeight)])
        // Disparity (2 floats)
        appendFloats(&plyData, [0.0, 1.0])
        // Color space (1 uchar: 0 = linear)
        plyData.append(UInt8(0))
        // Version (3 uchars)
        plyData.append(contentsOf: [UInt8(1), UInt8(0), UInt8(0)])

        // Write to file
        let outputName = imageURL.deletingPathExtension().lastPathComponent + ".ply"
        let outputURL = AppSettings.appSupportDir.appendingPathComponent(outputName)
        try plyData.write(to: outputURL)

        appLog("SHARPModelRunner: PLY file size: \(Double(plyData.count) / 1_000_000) MB")
        return outputURL
    }

    private func appendFloats(_ data: inout Data, _ values: [Float]) {
        var vals = values
        data.append(Data(bytes: &vals, count: vals.count * 4))
    }

    private func appendUInt32s(_ data: inout Data, _ values: [UInt32]) {
        var vals = values
        data.append(Data(bytes: &vals, count: vals.count * 4))
    }

    private func appendInt32s(_ data: inout Data, _ values: [Int32]) {
        var vals = values
        data.append(Data(bytes: &vals, count: vals.count * 4))
    }
}
