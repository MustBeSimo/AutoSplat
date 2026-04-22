import Foundation
import Combine

struct HFFile: Codable {
    let rfilename: String
    let size: Int?
}

struct HFModelInfo: Codable {
    let siblings: [HFFile]
}

class ModelDownloader: NSObject, ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private var repoId = "pearsonkyle/Sharp-coreml"
    private var cancellables = Set<AnyCancellable>()
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var totalBytes: Int64 = 0
    private var bytesFromFinishedFiles: Int64 = 0
    private var currentExpectedBytes: Int64 = 0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    var modelDir: URL {
        AppSettings.modelDirectory
    }

    var downloadPath: URL {
        AppSettings.appSupportDir.appendingPathComponent("Downloads")
    }

    func fetchFileList() async throws -> [HFFile] {
        let urlString = "https://huggingface.co/api/models/\(repoId)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        await MainActor.run {
            statusMessage = NSLocalizedString("msg_fetching_file_list", comment: "Fetching file list...")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        let modelInfo = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return modelInfo.siblings
    }

    /// Resolve the actual download size by issuing a HEAD request (follows redirects)
    private func resolveFileSize(url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let linkedSize = httpResponse.value(forHTTPHeaderField: "x-linked-size") {
                return Int64(linkedSize) ?? httpResponse.expectedContentLength
            }
            return response.expectedContentLength
        } catch {
            return 0
        }
    }

    func downloadModel() async {
        guard !isDownloading else { return }

        await MainActor.run {
            isDownloading = true
            progress = 0
            errorMessage = nil
            statusMessage = NSLocalizedString("downloading_model", comment: "Downloading model...")
        }

        do {
            let files = try await fetchFileList()

            // Download ALL files inside sharp.mlpackage/ (model.mlmodel, weights, Manifest.json)
            let mlPackageFiles = files.filter {
                $0.rfilename.hasPrefix("sharp.mlpackage/")
            }

            guard !mlPackageFiles.isEmpty else {
                throw URLError(.fileDoesNotExist)
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: downloadPath, withIntermediateDirectories: true)

            // Clean previous download
            let packageDir = modelDir.appendingPathComponent("sharp.mlpackage")
            try? fm.removeItem(at: packageDir)
            try? fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // Resolve sizes for progress tracking
            await MainActor.run {
                statusMessage = "Checking download size..."
            }

            var fileSizes: [Int64] = []
            for file in mlPackageFiles {
                let fileURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.rfilename)")!
                let size = await resolveFileSize(url: fileURL)
                fileSizes.append(size)
            }
            totalBytes = fileSizes.reduce(0, +)
            bytesFromFinishedFiles = 0

            print("ModelDownloader: Downloading \(mlPackageFiles.count) files, total \(totalBytes / 1_000_000)MB")

            for (index, file) in mlPackageFiles.enumerated() {
                let encodedPath = file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.rfilename
                let fileURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(encodedPath)")!
                currentExpectedBytes = fileSizes[index]

                await MainActor.run {
                    statusMessage = "\(NSLocalizedString("msg_downloading_files", comment: "Downloading")) \(file.rfilename.split(separator: "/").last ?? "")"
                }

                print("ModelDownloader: Downloading \(file.rfilename) (\(currentExpectedBytes / 1_000_000)MB)")
                let localURL = try await downloadFile(from: fileURL)

                // Place in the correct subdirectory structure
                let destPath = modelDir.appendingPathComponent(file.rfilename)
                let destDir = destPath.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                try? fm.removeItem(at: destPath)
                try fm.moveItem(at: localURL, to: destPath)

                bytesFromFinishedFiles += fileSizes[index]
                print("ModelDownloader: Completed \(file.rfilename)")
            }

            await MainActor.run {
                statusMessage = NSLocalizedString("msg_download_complete", comment: "Download complete")
                isDownloading = false
                progress = 1.0
            }
            print("ModelDownloader: All downloads complete")
        } catch {
            await MainActor.run {
                errorMessage = NSLocalizedString("err_download_failed", comment: "Download failed") + ": \(error.localizedDescription)"
                isDownloading = false
            }
            print("ModelDownloader: Error: \(error)")
        }
    }

    private func downloadFile(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func cancel() {
        session.invalidateAndCancel()
        isDownloading = false
        statusMessage = ""
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let tempDest = downloadPath.appendingPathComponent(UUID().uuidString)
        do {
            try? fm.createDirectory(at: downloadPath, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: tempDest)
            downloadContinuation?.resume(returning: tempDest)
        } catch {
            downloadContinuation?.resume(throwing: error)
        }
        downloadContinuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let currentFileProgress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        if totalBytes > 0 {
            let overallBytes = Double(bytesFromFinishedFiles) + Double(currentExpectedBytes) * currentFileProgress
            progress = overallBytes / Double(totalBytes)
        } else {
            progress = currentFileProgress
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }
}
