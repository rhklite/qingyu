import Foundation

/// What the cleanup step can offer, based on what's actually on the machine.
enum OllamaState {
    case unreachable        // Ollama isn't installed, or its server isn't running
    case needsModel         // server is up but the cleanup model hasn't been pulled
    case ready              // server is up and the model is there
}

/// Minimal Ollama HTTP client for the setup window: probe the server and pull the
/// cleanup model with progress.
///
/// Deliberately callback-based rather than async/await. The setup window runs a modal
/// session, and MainActor continuations hop through the main dispatch queue, which does
/// not drain in NSModalPanelRunLoopMode — the same trap that froze the whisper download
/// UI. Everything here reports through ModelDownloader.onMain instead.
final class OllamaClient: NSObject {
    struct PullProgress {
        let status: String
        let completed: Int64
        let total: Int64

        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    enum PullError: LocalizedError {
        case http(Int)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return "Ollama returned HTTP \(code)."
            case .server(let message): return message
            }
        }
    }

    private let baseURL: String
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var lastError: String?
    private var onProgress: ((PullProgress) -> Void)?
    private var onFinish: ((Result<Void, Error>) -> Void)?

    init(baseURL: String) {
        self.baseURL = baseURL
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Is Ollama up, and is `model` already pulled? Answers on the main run loop.
    func probe(model: String, completion: @escaping (OllamaState) -> Void) {
        guard let url = URL(string: baseURL + "/api/tags") else {
            ModelDownloader.onMain { completion(.unreachable) }
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            guard ok, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]]
            else {
                ModelDownloader.onMain { completion(.unreachable) }
                return
            }
            let names = models.compactMap { $0["name"] as? String }
            let state: OllamaState = Self.contains(names, model) ? .ready : .needsModel
            ModelDownloader.onMain { completion(state) }
        }.resume()
    }

    /// Ollama reports "qwen2.5:3b" for a pull of "qwen2.5:3b", but bare names come back
    /// tagged as ":latest" — match both ways so an installed model is never re-pulled.
    private static func contains(_ names: [String], _ wanted: String) -> Bool {
        let target = wanted.contains(":") ? wanted : wanted + ":latest"
        return names.contains { $0 == wanted || $0 == target }
    }

    func pull(model: String,
              onProgress: @escaping (PullProgress) -> Void,
              onFinish: @escaping (Result<Void, Error>) -> Void) {
        cancel()
        self.onProgress = onProgress
        self.onFinish = onFinish
        buffer = Data()
        lastError = nil

        guard let url = URL(string: baseURL + "/api/pull") else {
            finish(.failure(PullError.server("Bad Ollama URL.")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        task = session.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        onProgress = nil
        onFinish = nil
        task?.cancel()
        task = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = onFinish
        onFinish = nil
        onProgress = nil
        task = nil
        ModelDownloader.onMain { callback?(result) }
    }
}

extension OllamaClient: URLSessionDataDelegate {
    /// /api/pull streams newline-delimited JSON, one object per progress tick. Lines can
    /// straddle packet boundaries, so buffer and only parse complete ones.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        if let message = obj["error"] as? String {
            lastError = message
            return
        }

        let status = (obj["status"] as? String) ?? ""
        let completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
        let total = (obj["total"] as? NSNumber)?.int64Value ?? 0
        let progress = PullProgress(status: status, completed: completed, total: total)
        let callback = onProgress
        ModelDownloader.onMain { callback?(progress) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            finish(.failure(error))
            return
        }
        if let lastError {
            finish(.failure(PullError.server(lastError)))
            return
        }
        if let code = (task.response as? HTTPURLResponse)?.statusCode, code != 200 {
            finish(.failure(PullError.http(code)))
            return
        }
        finish(.success(()))
    }
}
