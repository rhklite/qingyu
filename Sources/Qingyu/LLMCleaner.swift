import Foundation

/// Optional post-processing pass that rewrites the raw transcript into clean
/// written text using a local Ollama model. Any failure (Ollama not running,
/// model not pulled, timeout) returns nil so the caller falls back to the raw
/// transcript — the app stays useful even without a local LLM installed.
struct LLMCleaner {
    let baseURL: String
    let model: String

    func cleanup(_ text: String, vocabulary: [String]) async -> String? {
        guard let url = URL(string: baseURL + "/api/generate") else { return nil }

        var prompt = """
        You are a dictation post-processor. Rewrite the raw speech-to-text \
        transcript below into clean written text. Fix punctuation and \
        capitalization; remove filler words (um, uh, like, you know) and false \
        starts; keep the wording faithful — do NOT add content, summarize, \
        translate, or answer questions in the text. Output ONLY the cleaned \
        text with no preamble.
        """
        if !vocabulary.isEmpty {
            prompt += "\nKnown proper nouns / spellings: " + vocabulary.joined(separator: ", ") + "."
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
        req.timeoutInterval = 20

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
