import Foundation

enum DownloadError: LocalizedError {
    case http(Int)
    case notAModel
    case truncated(got: Int64, expected: Int64)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "The server returned HTTP \(code)."
        case .notAModel:
            return "The downloaded file isn't a GGML model."
        case .truncated(let got, let expected):
            let g = ByteCountFormatter.string(fromByteCount: got, countStyle: .file)
            let e = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return "Download incomplete — got \(g) of \(e)."
        }
    }
}

/// Fetches a whisper model into ~/.config/qingyu/models with progress reporting.
///
/// The file is moved into place only after it passes a header + size check, so an
/// interrupted or corrupt download can never leave something that looks installed.
/// One downloader drives one download at a time; call `cancel()` to stop it.
final class ModelDownloader: NSObject {
    struct Progress {
        let received: Int64
        let total: Int64          // 0 when the server didn't send Content-Length
        let bytesPerSecond: Double

        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }

        /// nil when there's nothing to base an estimate on yet.
        var secondsRemaining: Double? {
            guard total > 0, bytesPerSecond > 1 else { return nil }
            return Double(total - received) / bytesPerSecond
        }
    }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var model: SpeechModel?
    private var startedAt = Date()
    private var onProgress: ((Progress) -> Void)?
    private var onFinish: ((Result<Void, Error>) -> Void)?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        // Half a gigabyte over a hotel Wi-Fi is a long time; don't time the whole
        // transfer out, only a genuinely stalled connection.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Callbacks are delivered on the main queue.
    func start(model: SpeechModel,
               onProgress: @escaping (Progress) -> Void,
               onFinish: @escaping (Result<Void, Error>) -> Void) {
        cancel()
        self.model = model
        self.onProgress = onProgress
        self.onFinish = onFinish
        startedAt = Date()
        try? FileManager.default.createDirectory(at: Config.modelsDir, withIntermediateDirectories: true)
        task = session.downloadTask(with: model.remoteURL)
        task?.resume()
    }

    /// Cancelling suppresses the completion callback — the caller already knows.
    func cancel() {
        onFinish = nil
        onProgress = nil
        task?.cancel()
        task = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = onFinish
        onFinish = nil
        onProgress = nil
        task = nil
        Self.onMain { callback?(result) }
    }

    /// The setup window runs a modal session, and plain `DispatchQueue.main.async`
    /// blocks do NOT drain in NSModalPanelRunLoopMode — progress would sit at
    /// "Connecting…" for the whole download. Schedule in the modes we actually need.
    static func onMain(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking], block: block)
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Content-Length is unknown (-1) on some CDN paths; fall back to the size we
        // already know the model to be, so the bar still means something.
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (model?.bytes ?? 0)
        let elapsed = Date().timeIntervalSince(startedAt)
        let progress = Progress(received: totalBytesWritten,
                                total: expected,
                                bytesPerSecond: elapsed > 0.5 ? Double(totalBytesWritten) / elapsed : 0)
        let callback = onProgress
        Self.onMain { callback?(progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // This callback owns `location` only until it returns — validate and move now.
        guard let model else { return }

        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            finish(.failure(DownloadError.http(response.statusCode)))
            return
        }

        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: location.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // A GGML model starts with the magic bytes 6c 6d 67 67. An HTML error page
        // saved under the right filename would otherwise sail through as "installed".
        var magicOK = false
        if let handle = try? FileHandle(forReadingFrom: location) {
            magicOK = ((try? handle.read(upToCount: 4)) ?? nil) == Data([0x6c, 0x6d, 0x67, 0x67])
            try? handle.close()
        }
        guard magicOK else {
            finish(.failure(DownloadError.notAModel))
            return
        }

        // Tolerate small upstream revisions, catch real truncation.
        if size < model.bytes / 2 {
            finish(.failure(DownloadError.truncated(got: size, expected: model.bytes)))
            return
        }

        do {
            let dest = model.localURL
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // didFinishDownloadingTo already reported success; only surface real failures,
        // and stay quiet about the cancellation the caller asked for.
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }
}
