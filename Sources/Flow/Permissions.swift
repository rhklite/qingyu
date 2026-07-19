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

/// Small audio cues so you know when recording starts/stops without watching the menu bar.
enum Cue {
    static func start() { NSSound(named: "Tink")?.play() }
    static func stop() { NSSound(named: "Pop")?.play() }
    static func error() { NSSound(named: "Basso")?.play() }
}
