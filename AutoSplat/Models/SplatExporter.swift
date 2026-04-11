import Foundation
import ModelIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case obj = "OBJ"
    case usdz = "USDZ"
    case ply = "PLY (Point Cloud)"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .obj: return "obj"
        case .usdz: return "usdz"
        case .ply: return "ply"
        }
    }
}

struct SplatVertex {
    let x: Float, y: Float, z: Float
    let r: Float, g: Float, b: Float
    let opacity: Float
}

class SplatExporter {

    /// Parse the binary PLY file and extract vertices with color
    static func parsePLY(at url: URL) throws -> [SplatVertex] {
        let data = try Data(contentsOf: url)

        // Find end_header
        guard let headerEnd = findHeaderEnd(in: data) else {
            throw ExportError.invalidPLY("Cannot find end_header")
        }

        // Parse header for vertex count
        let headerString = String(data: data[0..<headerEnd], encoding: .ascii) ?? ""
        guard let vertexCount = parseVertexCount(from: headerString) else {
            throw ExportError.invalidPLY("Cannot find element vertex count")
        }

        appLog("SplatExporter: Parsing \(vertexCount) vertices")

        // Each vertex: 14 floats (x y z f_dc_0 f_dc_1 f_dc_2 opacity scale_0 scale_1 scale_2 rot_0 rot_1 rot_2 rot_3)
        let bytesPerVertex = 14 * MemoryLayout<Float>.size  // 56 bytes
        let vertexDataStart = headerEnd
        let expectedSize = vertexDataStart + vertexCount * bytesPerVertex

        guard data.count >= expectedSize else {
            throw ExportError.invalidPLY("File too small: \(data.count) < \(expectedSize)")
        }

        let c0: Float = 0.28209479

        var vertices: [SplatVertex] = []
        vertices.reserveCapacity(vertexCount)

        data.withUnsafeBytes { raw in
            let floats = raw.baseAddress!.advanced(by: vertexDataStart)
                .assumingMemoryBound(to: Float.self)

            for i in 0..<vertexCount {
                let base = i * 14
                let x = floats[base + 0]
                let y = floats[base + 1]
                let z = floats[base + 2]

                // SH DC to sRGB: srgb = f_dc * C0 + 0.5
                let r = min(1, max(0, floats[base + 3] * c0 + 0.5))
                let g = min(1, max(0, floats[base + 4] * c0 + 0.5))
                let b = min(1, max(0, floats[base + 5] * c0 + 0.5))

                // Logit to alpha: alpha = sigmoid(logit)
                let logit = floats[base + 6]
                let alpha = 1.0 / (1.0 + exp(-logit))

                // Skip near-transparent splats
                if alpha < 0.05 { continue }

                vertices.append(SplatVertex(x: x, y: y, z: z, r: r, g: g, b: b, opacity: alpha))
            }
        }

        appLog("SplatExporter: Parsed \(vertices.count) visible vertices (filtered from \(vertexCount))")
        return vertices
    }

    // MARK: - OBJ Export

    static func exportOBJ(vertices: [SplatVertex], to url: URL) throws {
        appLog("SplatExporter: Writing OBJ with \(vertices.count) vertices")

        // Pre-allocate buffer (~50 bytes per line)
        var output = Data()
        output.reserveCapacity(vertices.count * 55)

        let header = "# AutoSplat OBJ Export\n# \(vertices.count) vertices\n# Built by Simone Leonelli — w230.net\n\n"
        output.append(header.data(using: .ascii)!)

        for v in vertices {
            // v x y z r g b (common OBJ extension for vertex color)
            let line = String(format: "v %.5f %.5f %.5f %.4f %.4f %.4f\n", v.x, v.y, v.z, v.r, v.g, v.b)
            output.append(line.data(using: .ascii)!)
        }

        try output.write(to: url)
        appLog("SplatExporter: OBJ saved (\(output.count / 1_000_000) MB)")
    }

    // MARK: - USDZ Export

    static func exportUSDZ(vertices: [SplatVertex], to url: URL) throws {
        appLog("SplatExporter: Writing USDZ with \(vertices.count) vertices")

        // Create interleaved position + color buffer
        let vertexCount = vertices.count
        let stride = MemoryLayout<Float>.size * 6  // 3 pos + 3 color = 24 bytes

        var buffer = Data(count: vertexCount * stride)
        buffer.withUnsafeMutableBytes { raw in
            let floats = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for (i, v) in vertices.enumerated() {
                let base = i * 6
                floats[base + 0] = v.x
                floats[base + 1] = v.y
                floats[base + 2] = v.z
                floats[base + 3] = v.r
                floats[base + 4] = v.g
                floats[base + 5] = v.b
            }
        }

        // Create MDL allocator and buffer
        let allocator = MDLMeshBufferDataAllocator()
        let mdlBuffer = allocator.newBuffer(with: buffer as Data, type: .vertex)

        // Vertex descriptor
        let descriptor = MDLVertexDescriptor()

        let posAttr = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        let colorAttr = MDLVertexAttribute(
            name: MDLVertexAttributeColor,
            format: .float3,
            offset: MemoryLayout<Float>.size * 3,
            bufferIndex: 0
        )
        descriptor.attributes = NSMutableArray(array: [posAttr, colorAttr])

        let layout = MDLVertexBufferLayout(stride: stride)
        descriptor.layouts = NSMutableArray(array: [layout])

        // Create submesh (points)
        let submesh = MDLSubmesh(
            name: "splats",
            indexBuffer: allocator.newBuffer(with: Data(), type: .index),
            indexCount: 0,
            indexType: .invalid,
            geometryType: .points,
            material: nil
        )

        // Create mesh
        let mesh = MDLMesh(
            vertexBuffer: mdlBuffer,
            vertexCount: vertexCount,
            descriptor: descriptor,
            submeshes: [submesh]
        )

        // Create asset and export
        let asset = MDLAsset()
        asset.add(mesh)

        // Try USDZ first, fall back to USDA
        if MDLAsset.canExportFileExtension("usdz") {
            try asset.export(to: url)
            appLog("SplatExporter: USDZ saved")
        } else {
            // Fallback: write USDA
            let usdaURL = url.deletingPathExtension().appendingPathExtension("usda")
            try asset.export(to: usdaURL)
            appLog("SplatExporter: USDA saved (USDZ not available)")
        }
    }

    // MARK: - PLY Point Cloud Export (simplified, no splat metadata)

    static func exportSimplePLY(vertices: [SplatVertex], to url: URL) throws {
        appLog("SplatExporter: Writing simple PLY with \(vertices.count) vertices")

        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property uchar alpha
        end_header\n
        """

        var data = Data()
        data.reserveCapacity(header.utf8.count + vertices.count * 16)
        data.append(header.data(using: .ascii)!)

        for v in vertices {
            var x = v.x, y = v.y, z = v.z
            data.append(Data(bytes: &x, count: 4))
            data.append(Data(bytes: &y, count: 4))
            data.append(Data(bytes: &z, count: 4))
            data.append(UInt8(v.r * 255))
            data.append(UInt8(v.g * 255))
            data.append(UInt8(v.b * 255))
            data.append(UInt8(v.opacity * 255))
        }

        try data.write(to: url)
        appLog("SplatExporter: PLY saved (\(data.count / 1_000_000) MB)")
    }

    // MARK: - Main Export

    static func export(plyURL: URL, to destinationURL: URL, format: ExportFormat) async throws {
        let vertices = try parsePLY(at: plyURL)

        switch format {
        case .obj:
            try exportOBJ(vertices: vertices, to: destinationURL)
        case .usdz:
            try exportUSDZ(vertices: vertices, to: destinationURL)
        case .ply:
            try exportSimplePLY(vertices: vertices, to: destinationURL)
        }
    }

    // MARK: - Helpers

    private static func findHeaderEnd(in data: Data) -> Int? {
        let marker = "end_header\n".data(using: .ascii)!
        guard let range = data.range(of: marker) else { return nil }
        return range.upperBound
    }

    private static func parseVertexCount(from header: String) -> Int? {
        for line in header.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("element vertex ") {
                return Int(trimmed.replacingOccurrences(of: "element vertex ", with: ""))
            }
        }
        return nil
    }

    enum ExportError: Error, LocalizedError {
        case invalidPLY(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPLY(let msg): return "Invalid PLY: \(msg)"
            case .exportFailed(let msg): return "Export failed: \(msg)"
            }
        }
    }
}
