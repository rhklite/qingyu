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

/// Everything that shapes one transcription. The defaults reproduce the original
/// decoder ("Vocabulary:" prompt, script as whisper wrote it) so that scripts/eval
/// can measure each change against what shipped.
struct DecodeOptions {
    var language = "auto"
    var detectLanguages: [String] = []
    var vocabulary: [String] = []
    /// Text before the cursor when dictation started; "" when unavailable or off.
    var context = ""
    /// Vocabulary as a plain term list fitted to whisper's prompt budget.
    var naturalPrompt = false
    /// Traditional → simplified characters on zh output. (A simplified-Chinese sentence
    /// in the prompt was tried too: it sent whisper into a repetition loop in the eval.)
    var simplifiedChinese = false
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
        // Intel builds ship without the Metal backend (ggml gates matmul on
        // MTLGPUFamilyApple7, which no Intel GPU reports), so run CPU + Accelerate.
        // flash_attn rides on the same simdgroup kernels — off there too.
        #if arch(arm64)
        cparams.use_gpu = true
        cparams.flash_attn = true
        #else
        cparams.use_gpu = false
        cparams.flash_attn = false
        #endif

        let created = modelPath.withCString { whisper_init_from_file_with_params($0, cparams) }
        guard let created else { throw WhisperError.modelLoadFailed }
        ctx = created
        loadedModelPath = modelPath
    }

    var isLoaded: Bool { ctx != nil }

    /// Leading silence prepended before whisper sees the audio.
    ///
    /// Push-to-talk hands whisper a clip that starts *mid-word*: the mic opens on the
    /// press and the user is already speaking. Whisper is trained on windows that ease
    /// in, and a waveform that jumps from nothing to a vowel at sample 0 reliably costs
    /// the first token — the "it always eats my first word" complaint. Half a second of
    /// silence gives the encoder the run-up it expects. It costs nothing: whisper pads
    /// every clip to 30 s internally regardless.
    private static let leadInSeconds = 0.5

    /// Silence, then a few milliseconds of ramp so the splice into speech isn't a step
    /// discontinuity — a hard edge is a broadband click, which is its own transcription
    /// hazard. The ramp is short enough not to swallow the onset it's protecting.
    private static func withLeadIn(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let pad = Int(leadInSeconds * 16_000)
        var out = [Float](repeating: 0, count: pad)
        out.reserveCapacity(pad + samples.count)
        out.append(contentsOf: samples)

        let ramp = min(80, samples.count)          // 5 ms at 16 kHz
        for i in 0..<ramp { out[pad + i] *= Float(i) / Float(ramp) }
        return out
    }

    func transcribe(samples rawSamples: [Float], options o: DecodeOptions) throws -> String {
        guard let ctx else { throw WhisperError.notLoaded }
        let samples = Self.withLeadIn(rawSamples)

        // Effective language: 1 selection = pin it; 2+ = restrict detection to that
        // subset (picks the most probable among them); none = the configured language.
        let effectiveLanguage: String
        if o.detectLanguages.count == 1 {
            effectiveLanguage = o.detectLanguages[0]
        } else if o.detectLanguages.count >= 2 {
            effectiveLanguage = detectLanguage(samples: samples, allowed: o.detectLanguages) ?? o.language
        } else {
            effectiveLanguage = o.language
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
        if let prompt = buildPrompt(o) {
            promptC = strdup(prompt)
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
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // whisper often writes Mandarin in traditional characters. ICU's transform leaves
        // Latin text alone, so mixed Chinese/English survives intact.
        if o.simplifiedChinese {
            let used = effectiveLanguage != "auto"
                ? effectiveLanguage
                : whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? ""
            if used == "zh" {
                text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
            }
        }
        return text
    }

    // MARK: Prompt

    /// whisper.cpp keeps at most n_text_ctx/2 (224) prompt tokens and silently drops
    /// the oldest beyond that; stay under it so the trimming is ours, not whisper's.
    private static let maxPromptTokens = 220
    /// Share of the budget the screen context may take before vocabulary gets the rest.
    private static let maxContextTokens = 100

    private func tokenCount(_ text: String) -> Int {
        guard let ctx, !text.isEmpty else { return 0 }
        var tokens = [whisper_token](repeating: 0, count: 512)
        let n = whisper_tokenize(ctx, text, &tokens, Int32(tokens.count))
        return Int(n < 0 ? -n : n)
    }

    /// The initial prompt: the vocabulary, then the text before the cursor — last,
    /// because whisper reads the prompt as the words spoken just before this clip.
    private func buildPrompt(_ o: DecodeOptions) -> String? {
        let context = o.context.trimmingCharacters(in: .whitespacesAndNewlines)

        // Original behaviour, kept exactly so it can be measured against.
        if !o.naturalPrompt && context.isEmpty {
            return o.vocabulary.isEmpty ? nil : "Vocabulary: " + o.vocabulary.joined(separator: ", ") + "."
        }

        var budget = Self.maxPromptTokens
        let contextTail = trimmedToTokens(context, max: min(Self.maxContextTokens, budget))
        budget -= tokenCount(contextTail)

        // Terms already on screen first, then the dictionary in its own order, until the
        // budget runs out — rather than letting whisper cut whatever came first.
        let lowered = context.lowercased()
        let ranked = o.vocabulary.filter { lowered.contains($0.lowercased()) }
            + o.vocabulary.filter { !lowered.contains($0.lowercased()) }
        func render(_ terms: [String]) -> String {
            o.naturalPrompt ? terms.joined(separator: ", ") + "."
                            : "Vocabulary: " + terms.joined(separator: ", ") + "."
        }
        var terms: [String] = []
        for term in ranked {
            if tokenCount(render(terms + [term])) > budget { break }
            terms.append(term)
        }

        let prompt = [terms.isEmpty ? "" : render(terms), contextTail]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return prompt.isEmpty ? nil : prompt
    }

    /// The end of `text` that fits in `max` tokens, cut at a word boundary.
    private func trimmedToTokens(_ text: String, max: Int) -> String {
        guard max > 0, !text.isEmpty else { return "" }
        var tail = Substring(text.suffix(800))
        while !tail.isEmpty, tokenCount(String(tail)) > max {
            tail = tail.dropFirst(Swift.max(1, tail.count / 8))
        }
        // Drop a half-cut leading word; Chinese has no spaces, so only look a little way in.
        if tail.startIndex != text.startIndex,
           let space = tail.prefix(20).firstIndex(where: { $0.isWhitespace }) {
            tail = tail[tail.index(after: space)...]
        }
        return String(tail)
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
