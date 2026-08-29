import Foundation

/// Turns spoken punctuation into real punctuation: "ship it question mark" → "ship it?".
///
/// Deliberately deterministic rather than left to the LLM. It has to work at the Raw
/// cleanup level and with Ollama absent, and a regex can't decide to be creative about
/// it. The LLM prompt reinforces the same behaviour for anything phrased unusually.
enum SpokenPunctuation {
    /// Marks that attach to the preceding word, eating the space before them.
    private static let attached: [(phrases: [String], mark: String)] = [
        (["period", "full stop"], "."),
        (["comma"], ","),
        (["question mark"], "?"),
        (["exclamation mark", "exclamation point"], "!"),
        (["colon"], ":"),
        (["semicolon", "semi colon"], ";"),
        (["ellipsis", "dot dot dot"], "…"),
        (["hyphen"], "-"),
        (["dash", "em dash"], " — "),
        (["close paren", "close parenthesis", "closed parenthesis"], ")"),
        (["close quote", "end quote", "unquote"], "”"),
    ]

    /// Marks that lead into the next word instead.
    private static let leading: [(phrases: [String], mark: String)] = [
        (["open paren", "open parenthesis"], "("),
        (["open quote", "begin quote"], "“"),
    ]

    private static let breaks: [(phrases: [String], mark: String)] = [
        (["new paragraph"], "\n\n"),
        (["new line", "newline"], "\n"),
    ]

    /// Chinese dictation says the names of full-width marks; whisper writes them out
    /// in Han characters, so they need their own table.
    private static let chinese: [(phrase: String, mark: String)] = [
        ("问号", "？"), ("句号", "。"), ("逗号", "，"), ("感叹号", "！"),
        ("冒号", "："), ("分号", "；"), ("顿号", "、"),
    ]

    static func apply(to text: String) -> String {
        var s = text

        for entry in breaks {
            for phrase in entry.phrases {
                s = replace(phrase, in: s, with: entry.mark, spacing: .none)
            }
        }
        for entry in attached {
            for phrase in entry.phrases {
                s = replace(phrase, in: s, with: entry.mark, spacing: .attachLeft)
            }
        }
        for entry in leading {
            for phrase in entry.phrases {
                s = replace(phrase, in: s, with: entry.mark, spacing: .attachRight)
            }
        }
        for entry in chinese {
            s = s.replacingOccurrences(of: entry.phrase, with: entry.mark)
        }

        return tidy(s)
    }

    private enum Spacing { case none, attachLeft, attachRight }

    /// Whole-word, case-insensitive. The word boundaries matter: without them "period"
    /// inside "periodically" would become "periodically" → "periodical.ly".
    private static func replace(_ phrase: String, in text: String,
                                with mark: String, spacing: Spacing) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // Allow an optional trailing comma/period that whisper may have added itself.
        let pattern: String
        switch spacing {
        case .attachLeft:  pattern = "\\s*\\b\(escaped)\\b[.,]?"
        case .attachRight: pattern = "\\b\(escaped)\\b[.,]?\\s*"
        case .none:        pattern = "\\s*\\b\(escaped)\\b[.,]?\\s*"
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: mark)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Collapse the artefacts the substitutions leave behind, and re-capitalise after
    /// sentence-ending marks so the result reads like written text.
    private static func tidy(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: " +([.,?!;:])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "([.,?!;:])(?=[^\\s.,?!;:)”])", with: "$1 ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n +", with: "\n", options: .regularExpression)
        s = capitalizeSentences(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var startOfSentence = true
        for i in chars.indices {
            let c = chars[i]
            if startOfSentence, c.isLetter {
                let upper = String(c).uppercased()
                if upper.count == 1 { chars[i] = Character(upper) }
                startOfSentence = false
            } else if ".?!\n".contains(c) {
                startOfSentence = true
            } else if !c.isWhitespace && c != "“" && c != "(" && c != "\"" {
                startOfSentence = false
            }
        }
        return String(chars)
    }
}
