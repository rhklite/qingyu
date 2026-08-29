import Foundation

/// User configuration, persisted at ~/.config/flow/config.json.
/// Missing keys fall back to defaults so old configs keep working after upgrades.
struct Config: Codable {
    var modelPath: String
    var language: String           // "auto" for detection, or "en", "ja", ...
    var pttKeyCode: Int            // CGKeyCode of the push-to-talk key
    var hotkeyMode: String        // "hold" | "toggle"
    var cleanup: Bool             // legacy on/off; kept in sync with cleanupLevel != .raw
    var cleanupLevel: String      // "raw" | "light" | "heavy" — see CleanupLevel
    var spokenPunctuation: Bool   // "question mark" → "?" before the LLM ever sees it
    var autoJargon: Bool          // offer unrecognized words for the dictionary after dictating
    var replacements: [String: String]  // literal find → replace, applied to every transcript
    var declinedJargon: [String]   // terms refused via the toast; never offered again
    var duckMode: String           // "off" | "lower" | "pause" — other audio while dictating
    var duckLevel: Double          // 0…1 gain for "lower"; 0 mutes
    var ollamaModel: String
    var ollamaURL: String
    var injectionMode: String     // "paste" | "type"
    var playSounds: Bool
    var customVocabulary: [String] // proper nouns / jargon to bias cleanup toward
    var inputDeviceUID: String?    // pinned CoreAudio input-device UID; nil = system default
    var showOverlay: Bool          // floating speech bar while dictating
    var overlayBottomMargin: Double // points above the Dock for the floating bar
    var boostAudio: Bool           // normalize quiet/far-mic audio before transcription
    var detectLanguages: [String]  // restrict detection to these whisper codes; [] = all
    var modelChosen: Bool          // user has picked a speech model; false = show setup on launch
    var modelsDir: String?         // where to keep speech models; nil = ~/.config/qingyu/models
    var remapEnabled: Bool         // send Return when the remap mouse button is pressed
    var remapButtonCode: Int       // HotKeyMonitor mouse code (1000 + button number)
    var autoCheckUpdates: Bool     // let Sparkle look for a new version on launch

    static let homeDir = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = homeDir.appendingPathComponent(".config/qingyu")
    static let defaultModelsDir = configDir.appendingPathComponent("models")
    static let configFile = configDir.appendingPathComponent("config.json")

    /// Where speech models live. Follows `modelsDir` in config.json so half a gigabyte
    /// can sit on an external drive; set from load(). Reverts to the default whenever
    /// the override is unusable — an unplugged drive shouldn't wedge the app.
    private(set) static var modelsDir = defaultModelsDir

    static func applyModelsDir(_ path: String?) {
        guard let path, !path.isEmpty else { modelsDir = defaultModelsDir; return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var isDir: ObjCBool = false
        let usable = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue && fm.isWritableFile(atPath: url.path)
        modelsDir = usable ? url : defaultModelsDir
    }

    static var `default`: Config {
        Config(
            modelPath: modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path,
            language: "auto",
            pttKeyCode: 58,          // kVK_Option (Left Option)
            hotkeyMode: "hybrid",    // hold to talk; double-tap to lock hands-free
            cleanup: true,
            cleanupLevel: CleanupLevel.light.rawValue,
            spokenPunctuation: true,
            autoJargon: true,
            replacements: [:],
            declinedJargon: [],
            duckMode: DuckSetting.off.rawValue,
            duckLevel: 0.25,
            ollamaModel: "qwen2.5:3b",
            ollamaURL: "http://127.0.0.1:11434",
            injectionMode: "paste",
            playSounds: true,
            customVocabulary: [],
            inputDeviceUID: nil,
            showOverlay: true,
            overlayBottomMargin: 20,
            boostAudio: true,
            detectLanguages: [],
            modelChosen: false,
            modelsDir: nil,
            remapEnabled: false,          // off until the user picks a button
            remapButtonCode: HotKeyMonitor.mouseCodeBase + 3,   // "mouse button 4"
            autoCheckUpdates: true
        )
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile) else {
            let cfg = Config.default
            applyModelsDir(nil)
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
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
        // Migrate configs written before cleanup had levels: the old boolean decides
        // which level they land on, and after that cleanupLevel is the source of truth.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["cleanupLevel"] == nil {
            cfg.cleanupLevel = ((obj["cleanup"] as? Bool) ?? true)
                ? CleanupLevel.light.rawValue : CleanupLevel.raw.rawValue
        }
        cfg.cleanup = cfg.level != .raw

        // Resolve the models directory before anything asks where models live.
        applyModelsDir(cfg.modelsDir)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return cfg
    }

    /// What to do with other audio while dictating; unknown strings mean off.
    var ducking: DuckSetting {
        get { DuckSetting(rawValue: duckMode) ?? .off }
        set { duckMode = newValue.rawValue }
    }

    /// Parsed cleanup level; unknown strings fall back to Light rather than silently
    /// disabling cleanup on someone who hand-edited the file.
    var level: CleanupLevel {
        get { CleanupLevel(rawValue: cleanupLevel) ?? .light }
        set { cleanupLevel = newValue.rawValue; cleanup = newValue != .raw }
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
        if let v = obj["cleanupLevel"] as? String { cleanupLevel = v }
        if let v = obj["spokenPunctuation"] as? Bool { spokenPunctuation = v }
        if let v = obj["autoJargon"] as? Bool { autoJargon = v }
        if let v = obj["replacements"] as? [String: String] { replacements = v }
        if let v = obj["declinedJargon"] as? [String] { declinedJargon = v }
        if let v = obj["duckMode"] as? String { duckMode = v }
        if let v = obj["duckLevel"] as? Double { duckLevel = v }
        if let v = obj["ollamaModel"] as? String { ollamaModel = v }
        if let v = obj["ollamaURL"] as? String { ollamaURL = v }
        if let v = obj["injectionMode"] as? String { injectionMode = v }
        if let v = obj["playSounds"] as? Bool { playSounds = v }
        if let v = obj["customVocabulary"] as? [String] { customVocabulary = v }
        if let v = obj["inputDeviceUID"] as? String { inputDeviceUID = v }
        if let v = obj["showOverlay"] as? Bool { showOverlay = v }
        if let v = obj["overlayBottomMargin"] as? Double { overlayBottomMargin = v }
        if let v = obj["boostAudio"] as? Bool { boostAudio = v }
        if let v = obj["detectLanguages"] as? [String] { detectLanguages = v }
        if let v = obj["modelChosen"] as? Bool { modelChosen = v }
        if let v = obj["modelsDir"] as? String { modelsDir = v }
        if let v = obj["remapEnabled"] as? Bool { remapEnabled = v }
        if let v = obj["remapButtonCode"] as? Int { remapButtonCode = v }
        if let v = obj["autoCheckUpdates"] as? Bool { autoCheckUpdates = v }
    }
}
