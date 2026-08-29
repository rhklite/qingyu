import AppKit
import NaturalLanguage

/// The personal dictionary: terms that bias transcription and cleanup, plus literal
/// find → replace pairs applied to every transcript.
enum PersonalDictionary {
    /// Apply find → replace pairs. Whole-word and case-insensitive, but the
    /// replacement's own capitalisation is kept — "claud" → "Claude" works regardless
    /// of how whisper capitalised it. Longest keys first so "git hub actions" wins over
    /// "git hub" when both are configured.
    static func applyReplacements(_ text: String, _ replacements: [String: String]) -> String {
        var out = text
        for key in replacements.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = replacements[key], !key.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
        return out
    }
}

/// Spots proper nouns and product/technical names worth teaching whisper.
///
/// Uses NaturalLanguage's on-device named-entity tagger plus casing signals. It
/// deliberately does NOT use NSSpellChecker: that routes through a system spell service
/// which hangs in this app's context (verified — it blocks indefinitely even inside a
/// real NSApplication), and a hang here would freeze the app after every dictation.
/// NLTagger is a local model with no service dependency.
///
/// No LLM involved either, so this runs at every cleanup level and can't invent a term
/// that was never said. It *can* still surface a mis-transcription, which is exactly
/// why the result is offered with an undo rather than filed silently.
@MainActor
enum JargonDetector {
    /// Words shorter than this are almost always noise rather than jargon.
    private static let minLength = 4

    /// Never offer these, however unusual they look.
    private static let ignored: Set<String> = [
        "gonna", "wanna", "kinda", "sorta", "gotta", "yeah", "yep", "nope", "okay",
        "uh", "um", "erm", "hmm", "mmm", "ahh", "ooh", "well", "just", "really",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    /// The single best candidate in `text`, or nil. One at a time on purpose — the
    /// toast asks about one word, and a queue of them would be worse than useless.
    static func candidate(in text: String, known: [String],
                          replacements: [String: String]) -> String? {
        let blocked = Set(known.map { $0.lowercased() })
            .union(replacements.keys.map { $0.lowercased() })
            .union(replacements.values.map { $0.lowercased() })

        func eligible(_ word: String) -> Bool {
            word.count >= minLength
                && !ignored.contains(word.lowercased())
                && !blocked.contains(word.lowercased())
                && word.allSatisfy { $0.isLetter }
                && word.unicodeScalars.allSatisfy { $0.isASCII }
        }

        // 1. Named entities — people, places, organisations. The strongest signal.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var namedEntity: String?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag,
                  [.personalName, .placeName, .organizationName].contains(tag) else { return true }
            let word = String(text[range])
            if eligible(word), namedEntity == nil { namedEntity = word }
            return namedEntity == nil
        }
        if let namedEntity { return namedEntity }

        // 2. Casing signals: internal capitals (GitHub, PyTorch, macOS) or an acronym.
        //    A word capitalised only because it starts a sentence proves nothing, so
        //    sentence-initial position is not itself a signal.
        var best: String?
        for word in text.split(whereSeparator: { !$0.isLetter }).map(String.init) {
            guard eligible(word) else { continue }
            let hasInnerCapital = word.dropFirst().contains { $0.isUppercase }
            let isAcronym = word.count >= 3 && word.allSatisfy { $0.isUppercase }
            guard hasInnerCapital || isAcronym else { continue }
            if best == nil || word.count > best!.count { best = word }
        }
        return best
    }
}
