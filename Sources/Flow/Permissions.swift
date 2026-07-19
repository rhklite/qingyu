import Cocoa
import AVFoundation

/// Thin wrappers around the three TCC permissions this app needs:
///   • Microphone       — to record.
///   • Input Monitoring — for the CGEvent tap that watches the hotkey.
///   • Accessibility    — to post synthetic key events (paste / typing).
enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    @discardableResult
    static func ensureInputMonitoring(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() { return true }
        if prompt { CGRequestListenEventAccess() }
        return false
    }

    @discardableResult
    static func ensurePostEvent(prompt: Bool) -> Bool {
        if CGPreflightPostEventAccess() { return true }
        if prompt { CGRequestPostEventAccess() }
        return false
    }

    // MARK: Status (for the menu so the user can see what's granted)

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static var postEventGranted: Bool { CGPreflightPostEventAccess() }

    /// True only when every permission the app needs is already granted.
    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted && postEventGranted
    }

    /// Fire every permission prompt the app needs in a single pass, so the user
    /// can grant them all at once instead of discovering them one feature at a time.
    static func requestAll() {
        requestMicrophone { _ in }
        ensureAccessibility(prompt: true)
        ensureInputMonitoring(prompt: true)
        ensurePostEvent(prompt: true)
    }

    /// Open System Settings → Privacy & Security. Pass a pane anchor
    /// ("Microphone", "Accessibility", "ListenEvent") to jump straight to that list.
    static func openPrivacySettings(pane: String? = nil) {
        var str = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        if let pane { str += "_" + pane }
        if let url = URL(string: str) { NSWorkspace.shared.open(url) }
    }
}

/// Soft synthesized cues (Wispr-style): subtle two-note chimes instead of the clunky
/// system sounds. Rendered to in-memory WAV, so there are no asset files to ship.
/// Tweak the frequencies / volume below to taste.
enum Cue {
    private static let startWAV = chime(freqs: [660, 988], noteDur: 0.07, volume: 0.16)  // rising  E5→B5
    private static let stopWAV  = chime(freqs: [988, 660], noteDur: 0.07, volume: 0.14)  // falling B5→E5
    private static let errorWAV = chime(freqs: [392, 294], noteDur: 0.11, volume: 0.18)  // low, duller

    static func start() { NSSound(data: startWAV)?.play() }
    static func stop()  { NSSound(data: stopWAV)?.play() }
    static func error() { NSSound(data: errorWAV)?.play() }

    /// Sequence of pure-sine notes, each with a short attack/release so there are no clicks.
    private static func chime(freqs: [Double], noteDur: Double, volume: Double,
                              sampleRate: Double = 44_100) -> Data {
        var samples: [Int16] = []
        let attack = 0.006, release = 0.03
        for f in freqs {
            let n = Int(noteDur * sampleRate)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                var env = 1.0
                if t < attack { env = t / attack }
                let remaining = noteDur - t
                if remaining < release { env = min(env, remaining / release) }
                let s = sin(2.0 * .pi * f * t) * env * volume
                samples.append(Int16(max(-1.0, min(1.0, s)) * 32_767))
            }
        }
        return wav(samples, Int(sampleRate))
    }

    /// Wrap mono 16-bit PCM samples in a minimal RIFF/WAVE container.
    private static func wav(_ samples: [Int16], _ sampleRate: Int) -> Data {
        var d = Data()
        let dataSize = samples.count * 2
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)                          // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(dataSize))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}
