import Foundation

/// User configuration, persisted at ~/.config/flow/config.json.
/// Missing keys fall back to defaults so old configs keep working after upgrades.
struct Config: Codable {
    var modelPath: String
    var language: String           // "auto" for detection, or "en", "ja", ...
    var pttKeyCode: Int            // CGKeyCode of the push-to-talk key
    var hotkeyMode: String        // "hold" | "toggle"
    var cleanup: Bool             // run the local-LLM cleanup pass
    var ollamaModel: String
    var ollamaURL: String
    var injectionMode: String     // "paste" | "type"
    var playSounds: Bool
    var customVocabulary: [String] // proper nouns / jargon to bias cleanup toward
    var inputDeviceUID: String?    // pinned CoreAudio input-device UID; nil = system default
    var showOverlay: Bool          // floating speech bar while dictating
    var boostAudio: Bool           // normalize quiet/far-mic audio before transcription
    var detectLanguages: [String]  // restrict detection to these whisper codes; [] = all

    static let homeDir = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = homeDir.appendingPathComponent(".config/qingyu")
    static let modelsDir = configDir.appendingPathComponent("models")
    static let configFile = configDir.appendingPathComponent("config.json")

    static var `default`: Config {
        Config(
            modelPath: modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path,
            language: "auto",
            pttKeyCode: 58,          // kVK_Option (Left Option)
            hotkeyMode: "hybrid",    // hold to talk; double-tap to lock hands-free
            cleanup: true,
            ollamaModel: "qwen2.5:3b",
            ollamaURL: "http://127.0.0.1:11434",
            injectionMode: "paste",
            playSounds: true,
            customVocabulary: [],
            inputDeviceUID: nil,
            showOverlay: true,
            boostAudio: true,
            detectLanguages: []
        )
    }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: configFile) else {
            let cfg = Config.default
            cfg.save()
            return cfg
        }
        // Decode leniently: start from defaults, overlay whatever the file provides.
        var cfg = Config.default
        if let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg.apply(obj)
        }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    /// Overlay a partial JSON object onto this config (forward-compat for hand-edited files).
    private mutating func apply(_ obj: [String: Any]) {
        if let v = obj["modelPath"] as? String { modelPath = v }
        if let v = obj["language"] as? String { language = v }
        if let v = obj["pttKeyCode"] as? Int { pttKeyCode = v }
        if let v = obj["hotkeyMode"] as? String { hotkeyMode = v }
        if let v = obj["cleanup"] as? Bool { cleanup = v }
        if let v = obj["ollamaModel"] as? String { ollamaModel = v }
        if let v = obj["ollamaURL"] as? String { ollamaURL = v }
        if let v = obj["injectionMode"] as? String { injectionMode = v }
        if let v = obj["playSounds"] as? Bool { playSounds = v }
        if let v = obj["customVocabulary"] as? [String] { customVocabulary = v }
        if let v = obj["inputDeviceUID"] as? String { inputDeviceUID = v }
        if let v = obj["showOverlay"] as? Bool { showOverlay = v }
        if let v = obj["boostAudio"] as? Bool { boostAudio = v }
        if let v = obj["detectLanguages"] as? [String] { detectLanguages = v }
    }
}
