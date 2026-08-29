import Foundation

/// Optional post-processing pass that rewrites the raw transcript into clean
/// written text using a local Ollama model. Any failure (Ollama not running,
/// model not pulled, timeout) returns nil so the caller falls back to the raw
/// transcript — the app stays useful even without a local LLM installed.
struct LLMCleaner {
    let baseURL: String
    let model: String
    let level: CleanupLevel

    func cleanup(_ text: String, vocabulary: [String], spokenPunctuation: Bool) async -> String? {
        guard let instruction = level.prompt,
              let url = URL(string: baseURL + "/api/generate") else { return nil }

        var prompt = instruction
        if spokenPunctuation {
            // SpokenPunctuation already did the common phrasings deterministically;
            // this catches anything said unusually ("open bracket", "full stop there").
            prompt += "\nIf the transcript names a punctuation mark out loud "
                + "(\"question mark\", \"comma\", \"new line\"), replace it with the mark itself."
        }
        if !vocabulary.isEmpty {
            prompt += "\nKnown proper nouns / spellings, keep them spelled exactly like this: "
                + vocabulary.joined(separator: ", ") + "."
        }
        prompt += "\n\nTranscript:\n\(text)\n\nCleaned text:"

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.2],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Heavy rewrites more text and thinks longer; a 20s ceiling silently degraded
        // it to raw output on longer dictations.
        req.timeoutInterval = level == .heavy ? 45 : 20

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = obj["response"] as? String else { return nil }
            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    /// Cheap reachability probe used to reflect Ollama status in the menu.
    static func isReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
