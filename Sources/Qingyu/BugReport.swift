import Cocoa
import AVFoundation

/// Builds a plain-text bug report and hands it over in whichever form suits the person
/// reporting: a .txt file to attach to a message, the same text on the clipboard, or a
/// prefilled GitHub issue.
///
/// The text file is the one that matters day to day — the people using 轻语 are friends
/// texting back and forth, not people who will open a GitHub account to say the mic
/// stopped working. Everything is gathered automatically, because a report that asks the
/// reporter which model they're on gets back "the normal one".
@MainActor
enum BugReport {
    static let issueURL = "https://github.com/rhklite/qingyu/issues/new"

    /// Everything worth knowing about a 轻语 that is misbehaving, in the order someone
    /// diagnosing it would want to read.
    static func text(config: Config, state: String, lastError: String?,
                     recentLog: [String]) -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let uptime = Int(ProcessInfo.processInfo.systemUptime)

        var out = """
        轻语 bug report
        ================================================================

        WHAT WENT WRONG
          (describe it here in a sentence or two — what you did, what happened)


        ----------------------------------------------------------------
        VERSION
          轻语              \(version) (build \(build))
          macOS             \(os)
          Mac               \(hardware())
          Running for       \(uptime / 60) min

        PERMISSIONS
          Microphone        \(mark(Permissions.microphoneGranted))
          Accessibility     \(mark(Permissions.accessibilityGranted))
          Input Monitoring  \(mark(Permissions.inputMonitoringGranted))

        STATE
          Status            \(state)
        """

        if let lastError, !lastError.isEmpty {
            out += "\n  Last error        \(lastError)"
        }

        out += """


        SETTINGS
          Push-to-talk      \(HotkeyCapture.name(for: config.pttKeyCode))  (\(config.hotkeyMode))
          Mouse → Return    \(config.remapEnabled
                                ? HotkeyCapture.name(for: config.remapButtonCode)
                                : "off")
          Speech model      \((config.modelPath as NSString).lastPathComponent)
          Model present     \(mark(FileManager.default.fileExists(atPath: config.modelPath)))
          Language          \(languageSummary(config))
          Cleanup           \(config.level.title)\(config.level == .raw ? "" : " via \(config.ollamaModel)")
          Microphone        \(micSummary(config))
          Boost quiet audio \(config.boostAudio ? "on" : "off")
          Spoken punctuation \(config.spokenPunctuation ? "on" : "off")
          Floating bar      \(config.showOverlay ? "on" : "off")
          Other audio       \(config.ducking.title)
          Injection         \(config.injectionMode)

        AUDIO INPUTS SEEN
        """

        let inputs = AudioDevices.inputs()
        out += inputs.isEmpty
            ? "\n  (none — that alone would explain a dead microphone)"
            : inputs.map { "\n  • \($0.name)" }.joined()

        out += "\n\nRECENT ACTIVITY\n"
        out += recentLog.isEmpty
            ? "  (nothing recorded this session)"
            : recentLog.map { "  \($0)" }.joined(separator: "\n")

        out += "\n\n================================================================\n"
        return out
    }

    /// Write the report next to everything else the user might attach to a message, and
    /// put it on the clipboard too so a paste works without hunting for the file.
    /// Returns the file URL, or nil if it couldn't be written (the clipboard still has it).
    @discardableResult
    static func save(_ text: String) -> URL? {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime,
                               .withDashSeparatorInDate, .withColonSeparatorInTime]
        let name = "qingyu-bug-report-"
            + stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")
            + ".txt"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desktop.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("Qingyu: could not write bug report: %@", error.localizedDescription as NSString)
            return nil
        }
    }

    /// GitHub caps a prefilled issue body at what fits in a URL; anything longer is
    /// truncated by the server with no warning, so trim it here and say we did.
    static func githubURL(title: String, body: String) -> URL? {
        let limit = 6_000
        let trimmed = body.count > limit
            ? String(body.prefix(limit)) + "\n\n…truncated — the full report is on your clipboard."
            : body
        var components = URLComponents(string: issueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: trimmed),
        ]
        return components?.url
    }

    // MARK: Bits

    private static func mark(_ granted: Bool) -> String { granted ? "granted" : "NOT GRANTED" }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        let model = String(cString: chars)
        #if arch(arm64)
        return "\(model) (Apple Silicon)"
        #else
        return "\(model) (Intel)"
        #endif
    }

    private static func languageSummary(_ config: Config) -> String {
        switch config.detectLanguages.count {
        case 0:  return "auto-detect (all)"
        case 1:  return "pinned to \(Language.label(config.detectLanguages[0]))"
        default: return "detect among " + config.detectLanguages.map(Language.shortLabel)
                                                .joined(separator: ", ")
        }
    }

    private static func micSummary(_ config: Config) -> String {
        guard let uid = config.inputDeviceUID, !uid.isEmpty else { return "system default" }
        let connected = AudioDevices.inputs().first { $0.uid == uid }
        return connected.map { "pinned to \($0.name)" }
            ?? "pinned to a device that is NOT connected (\(uid))"
    }
}

/// A small ring of recent events, so a report can say what the app was doing rather than
/// only what it was configured to do. Kept in memory only — nothing is written anywhere
/// until the user asks for a report.
@MainActor
final class ActivityLog {
    static let shared = ActivityLog()
    private var lines: [String] = []
    private let limit = 40

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func record(_ message: String) {
        lines.append("\(formatter.string(from: Date()))  \(message)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    var recent: [String] { lines }
}

