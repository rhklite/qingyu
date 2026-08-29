import Cocoa
import CoreGraphics

/// Marks the key events 轻语 posts itself, so the push-to-talk tap can tell its own
/// paste/typing from the keystrokes a remapper sends on the user's behalf.
///
/// The distinction matters because the tap has to reject the first — pasting with ⌘V
/// while ⌘ is the talk key would retrigger dictation forever — while accepting the
/// second, which is the whole point of mapping a mouse button to the talk key.
enum SyntheticEvent {
    /// Arbitrary marker written into a field macOS carries through untouched.
    static let tag: Int64 = 0x515955          // "QYU"

    static func mark(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: tag)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }
}

/// Watches a single global push-to-talk key — or mouse button — via a listen-only
/// CGEvent tap. Reports .down / .up transitions on the main thread. A modifier key (the
/// default Right-Option, keycode 61) is recommended so the key never types a
/// character into the focused app while held.
final class HotKeyMonitor {
    enum Key { case down, up }

    /// Push-to-talk can be an extra mouse button instead of a key. Those are stored as
    /// this base plus the button number, so one config field still covers both and old
    /// configs — every value below the base — keep meaning exactly what they did.
    static let mouseCodeBase = 1000

    static func isMouseButton(_ code: Int) -> Bool { code >= mouseCodeBase }
    static func mouseButton(from code: Int) -> Int64 { Int64(code - mouseCodeBase) }

    private let keyCode: Int64
    private let mouseButton: Int64?
    private let onEvent: (Key) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(keyCode: Int, onEvent: @escaping (Key) -> Void) {
        self.keyCode = Int64(keyCode)
        self.mouseButton = Self.isMouseButton(keyCode) ? Self.mouseButton(from: keyCode) : nil
        self.onEvent = onEvent
    }

    /// Returns false if the tap could not be created (missing Input Monitoring permission).
    func start() -> Bool {
        // Extra mouse buttons are watched too, so a Logitech side button can be the talk
        // button with nothing mapped onto it in G-Hub or Options+. Left and right click
        // are deliberately absent — binding those would make the mouse unusable.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    /// True while the tap exists and macOS still has it switched on. Worth polling: the
    /// system turns off a tap whose owner answered too slowly, and an idle background
    /// app is exactly what that looks like.
    var isActive: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Switch a disabled tap back on. Returns false when the tap is gone for good and
    /// the caller has to build a fresh one.
    @discardableResult
    func reviveIfNeeded() -> Bool {
        guard let tap else { return false }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        forgetKeyState()
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Any gap in the event stream can swallow the key-up that ended the last press.
    /// Clearing the latch means the next press is seen as a press instead of being
    /// filtered as a repeat of one that never ended.
    private func forgetKeyState() { isDown = false }

    // Runs on the main run loop (the tap source is attached there).
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            forgetKeyState()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Only 轻语's own paste/typing is rejected. Events posted by anything else are
        // the user pressing something — a Logitech button mapped to a keystroke in G-Hub
        // or Options+ arrives exactly this way, carrying that app's PID.
        if SyntheticEvent.isOurs(event) { return }

        if let mouseButton {
            guard event.getIntegerValueField(.mouseEventButtonNumber) == mouseButton else { return }
            switch type {
            case .otherMouseDown: transition(to: true)
            case .otherMouseUp: transition(to: false)
            default: break
            }
            return
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }

        switch type {
        case .flagsChanged: transition(to: modifierIsDown(event))
        case .keyDown: transition(to: true)
        case .keyUp: transition(to: false)
        default: break
        }
    }

    private func modifierIsDown(_ event: CGEvent) -> Bool {
        let flags = event.flags
        switch keyCode {
        case 61, 58: return flags.contains(.maskAlternate)   // right / left option
        case 62, 59: return flags.contains(.maskControl)     // right / left control
        case 60, 56: return flags.contains(.maskShift)       // right / left shift
        case 54, 55: return flags.contains(.maskCommand)     // right / left command
        default: return !isDown
        }
    }

    private func transition(to down: Bool) {
        guard down != isDown else { return }   // ignore key-repeat and no-op flag changes
        isDown = down
        onEvent(down ? .down : .up)
    }
}
