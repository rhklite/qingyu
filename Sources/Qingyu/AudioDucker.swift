import AppKit

/// How 轻语 treats other audio while you dictate. Off by default — it's an extra, and
/// it needs a system-audio permission the rest of the app doesn't.
enum DuckSetting: String, CaseIterable {
    case off
    case lower   // duck background audio to `duckLevel` and restore it after
    case pause   // pause the Now Playing source and resume it after

    var title: String {
        switch self {
        case .off:   return "Leave audio alone"
        case .lower: return "Lower other audio"
        case .pause: return "Pause media"
        }
    }

    var blurb: String {
        switch self {
        case .off:
            return "Other audio keeps playing while you dictate."
        case .lower:
            return "Music, video and browser audio drop to a quieter level while you talk, "
                 + "then return. Works on anything that makes sound."
        case .pause:
            return "Pauses whatever is playing (Music, Spotify, Safari, Chrome, a phone "
                 + "AirPlaying to this Mac) and resumes it when you stop."
        }
    }
}

/// Wraps the vendored speak-duck engine so the rest of 轻语 never has to think about
/// macOS 14.4 availability or Core Audio.
///
/// Everything here is a no-op when the feature is off or the OS is too old, so callers
/// can just say `ducker.dictating = true` and forget about it.
@MainActor
final class AudioDucker {
    /// False on macOS 13 — the process-tap API this needs is 14.4+.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private var engine: AnyObject?
    private var setting: DuckSetting = .off
    private var level: Double = 0.25

    /// Apply the user's configuration, starting or stopping the engine as needed.
    func configure(setting: DuckSetting, level: Double) {
        self.setting = setting
        self.level = level
        guard Self.isSupported else { return }
        guard #available(macOS 14.4, *) else { return }

        guard setting != .off else { teardown(); return }

        let engine = existingEngine ?? {
            // voiceBundle is speak-duck's "Spoken Content is talking" trigger, which
            // 轻语 doesn't use; the manual flag drives everything here.
            let e = DuckEngine(voiceBundle: "com.apple.SpeechSynthesisServer",
                               resumeDelay: 0.35, duckLevel: Float(level))
            e.sendPause = { MediaRemoteBridge.pause() }
            e.sendPlay = { MediaRemoteBridge.play() }
            e.pauseWhileDictating = true
            e.start()
            self.engine = e
            return e
        }()
        engine.duckLevel = Float(level)
        engine.mode = (setting == .pause) ? .pause : .duck
    }

    /// Called around recording. Safe to set even when the feature is off.
    var dictating: Bool = false {
        didSet {
            guard #available(macOS 14.4, *), let engine = existingEngine else { return }
            engine.manualDictating = dictating
        }
    }

    @available(macOS 14.4, *)
    private var existingEngine: DuckEngine? { engine as? DuckEngine }

    private func teardown() {
        guard #available(macOS 14.4, *), let engine = existingEngine else { return }
        engine.stop()
        self.engine = nil
    }
}

/// MediaRemote pause/play — the same private path Control Center's transport controls
/// use. Core Audio can intercept a stream but cannot pause its source, so pausing has
/// to go through here. Resolved with dlopen so a missing symbol degrades to a no-op
/// instead of failing to launch.
enum MediaRemoteBridge {
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen(
                "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    private static let kPause: Int32 = 1
    private static let kPlay: Int32 = 0

    static func pause() { _ = sendCommand?(kPause, nil) }
    static func play() { _ = sendCommand?(kPlay, nil) }
}
