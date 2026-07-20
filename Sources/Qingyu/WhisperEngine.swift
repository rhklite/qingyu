import Foundation
import CWhisper

enum WhisperError: Error, LocalizedError {
    case modelMissing(String)
    case modelLoadFailed
    case notLoaded
    case transcribeFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return "Model file not found at \(p)"
        case .modelLoadFailed: return "Failed to load whisper model"
        case .notLoaded: return "Model not loaded"
        case .transcribeFailed: return "whisper_full failed"
        }
    }
}

/// Serialized wrapper around a whisper.cpp context. whisper contexts are not
/// thread-safe, so the actor guarantees one call at a time.
actor WhisperEngine {
    private var ctx: OpaquePointer?
    private(set) var loadedModelPath: String?

    func load(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelMissing(modelPath)
        }
        if let ctx { whisper_free(ctx); self.ctx = nil }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        let created = modelPath.withCString { whisper_init_from_file_with_params($0, cparams) }
        guard let created else { throw WhisperError.modelLoadFailed }
        ctx = created
        loadedModelPath = modelPath
    }

    var isLoaded: Bool { ctx != nil }

    func transcribe(samples: [Float], language: String, detectLanguages: [String],
                    vocabulary: [String]) throws -> String {
        guard let ctx else { throw WhisperError.notLoaded }

        // Effective language: 1 selection = pin it; 2+ = restrict detection to that
        // subset (picks the most probable among them); none = the configured language.
        let effectiveLanguage: String
        if detectLanguages.count == 1 {
            effectiveLanguage = detectLanguages[0]
        } else if detectLanguages.count >= 2 {
            effectiveLanguage = detectLanguage(samples: samples, allowed: detectLanguages) ?? language
        } else {
            effectiveLanguage = language
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        params.n_threads = Int32(threads)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        params.temperature = 0.0

        // These C strings must outlive the whisper_full call below.
        let langC = strdup(effectiveLanguage)
        defer { free(langC) }
        params.language = UnsafePointer(langC)

        var promptC: UnsafeMutablePointer<CChar>?
        if !vocabulary.isEmpty {
            promptC = strdup("Vocabulary: " + vocabulary.joined(separator: ", ") + ".")
            params.initial_prompt = UnsafePointer(promptC)
        }
        defer { if let promptC { free(promptC) } }

        let ret = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard ret == 0 else { throw WhisperError.transcribeFailed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run whisper's language detector and return the most probable language among
    /// `allowed` (whisper codes like "en", "zh"), or nil on failure. This is what makes
    /// "detect only among my languages" work — the pick is constrained to the subset.
    private func detectLanguage(samples: [Float], allowed: [String]) -> String? {
        guard let ctx, !allowed.isEmpty else { return nil }
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        // Language ID only needs a few seconds; cap the detection audio to stay cheap.
        let clip = samples.count > 16_000 * 10 ? Array(samples.prefix(16_000 * 10)) : samples
        let melOK = clip.withUnsafeBufferPointer {
            whisper_pcm_to_mel(ctx, $0.baseAddress, Int32($0.count), threads)
        }
        guard melOK == 0 else { return nil }

        let maxId = Int(whisper_lang_max_id())
        var probs = [Float](repeating: 0, count: maxId + 1)
        let top = probs.withUnsafeMutableBufferPointer {
            whisper_lang_auto_detect(ctx, 0, threads, $0.baseAddress)
        }
        guard top >= 0 else { return nil }

        var best: (code: String, p: Float)?
        for code in allowed {
            let id = Int(code.withCString { whisper_lang_id($0) })
            guard id >= 0, id <= maxId else { continue }
            if best == nil || probs[id] > best!.p { best = (code, probs[id]) }
        }
        return best?.code
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }
}
