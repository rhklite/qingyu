import Foundation

/// Replays a test set (scripts/eval/extract_wispr.py) through the app's own
/// WhisperEngine under named decoder settings, and writes one JSON line per clip.
/// Build and run via scripts/eval/run_eval.sh; score with scripts/eval/score.py.
///
/// A setting is a "+"-joined list of changes on top of the shipped decoder, e.g.
/// "baseline", "natural", "natural+zh". Audio boost, languages, vocabulary and
/// replacements come from ~/.config/qingyu/config.json, as in the app.

struct Clip: Decodable {
    let id: String
    let wav: String
    let ref: String
    let lang: String
}

/// 16-bit PCM mono WAV → floats in -1…1. Walks the chunks rather than assuming a
/// 44-byte header, since writers may add LIST/fact chunks before "data".
func readWAV(_ path: String) -> [Float]? {
    guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i + 4], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" {
            let start = i + 8, end = min(d.count, start + size)
            return stride(from: start, to: end - 1, by: 2).map {
                Float(Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8)) / 32768
            }
        }
        i += 8 + size + (size & 1)
    }
    return nil
}

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return fallback
}

@main
struct Eval {
    static func main() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cfgData = FileManager.default.contents(atPath: home + "/.config/qingyu/config.json") ?? Data("{}".utf8)
        let cfg = (try JSONSerialization.jsonObject(with: cfgData) as? [String: Any]) ?? [:]


        let manifest = arg("--manifest", home + "/.config/qingyu/eval/manifest.jsonl")
        let out = arg("--out", home + "/.config/qingyu/eval/hyps.jsonl")
        let model = arg("--model", cfg["modelPath"] as? String ?? "")
        let settings = arg("--settings", "baseline").split(separator: ",").map(String.init)
        let limit = Int(arg("--limit", "0")) ?? 0

        var base = DecodeOptions()
        base.language = cfg["language"] as? String ?? "auto"
        base.detectLanguages = cfg["detectLanguages"] as? [String] ?? []
        base.vocabulary = cfg["customVocabulary"] as? [String] ?? []
        let replacements = cfg["replacements"] as? [String: String] ?? [:]
        let boost = cfg["boostAudio"] as? Bool ?? true

        var clips = try String(contentsOfFile: manifest, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        if limit > 0 { clips = Array(clips.prefix(limit)) }

        let engine = WhisperEngine()
        try await engine.load(modelPath: model)
        FileManager.default.createFile(atPath: out, contents: nil)
        let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: out))

        for setting in settings {
            var total = 0.0
            for clip in clips {
                guard var samples = readWAV(clip.wav) else { continue }
                if boost { samples = AudioRecorder.normalizedForRecognition(samples) }

                var o = base
                for change in setting.split(separator: "+") {
                    switch change {
                    case "baseline": break
                    case "natural": o.naturalPrompt = true
                    case "zh": o.simplifiedChinese = true
                    default: fatalError("unknown change '\(change)' in setting '\(setting)'")
                    }
                }

                let t0 = Date()
                let raw = try await engine.transcribe(samples: samples, options: o)
                let secs = Date().timeIntervalSince(t0)
                total += secs

                let row: [String: Any] = [
                    "setting": setting, "id": clip.id, "lang": clip.lang, "secs": secs,
                    "hyp": PersonalDictionary.applyReplacements(raw, replacements),
                    "ref": PersonalDictionary.applyReplacements(clip.ref, replacements),
                ]
                sink.write(try JSONSerialization.data(withJSONObject: row))
                sink.write(Data("\n".utf8))
            }
            print(String(format: "%@: %d clips, %.2fs per clip", setting, clips.count, total / Double(max(1, clips.count))))
        }
        try sink.close()
    }
}
