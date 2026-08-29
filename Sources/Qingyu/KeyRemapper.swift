import Cocoa
import CoreGraphics

/// Turns a mouse button into a keystroke, system-wide, for as long as 轻语 is running.
///
/// The point is the pair with dictation: talk, then press the same thumb button to send
/// what you just dictated, without leaving the mouse for the keyboard. Mouse software
/// like G-Hub or Options+ can do this too, but only per-device and per-profile — doing it
/// here means it follows the Mac rather than the mouse.
///
/// Unlike `HotKeyMonitor` this tap is NOT listen-only: swallowing the original button
/// press is the whole feature, since a middle-click that also pastes, or a side button
/// that also goes Back, would fire alongside the Return. An active tap needs
/// Accessibility (Input Monitoring is not enough), so `start()` reports failure and the
/// caller says so rather than leaving a dead setting switched on.
@MainActor
final class KeyRemapper {
    /// Return / Enter. The one worth having: it submits a chat box, a terminal line, a
    /// search field — the things you dictate into.
    static let returnKeyCode: CGKeyCode = 36

    private let mouseButton: Int64
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Guards against a button-up with no matching down — a real risk when the tap is
    /// disabled mid-click — leaving a Return key stuck down in the target app.
    private var isDown = false

    init(mouseButtonCode: Int) {
        self.mouseButton = Int64(HotKeyMonitor.mouseButton(from: mouseButtonCode))
    }

    /// Returns false when the tap can't be created, which in practice means Accessibility
    /// hasn't been granted.
    func start() -> Bool {
        let mask = (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let remapper = Unmanaged<KeyRemapper>.fromOpaque(refcon!).takeUnretainedValue()
            return remapper.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // active: we need to swallow the button
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
        // Never leave Return held down in whatever app had focus.
        if isDown { postReturn(down: false); isDown = false }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    var isActive: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Same watchdog contract as `HotKeyMonitor`: macOS switches off a tap whose owner
    /// was slow to answer, and tells only the tap itself.
    @discardableResult
    func reviveIfNeeded() -> Bool {
        guard let tap else { return false }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        if isDown { postReturn(down: false); isDown = false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // Runs on the main run loop. Returning nil swallows the event.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isDown { postReturn(down: false); isDown = false }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Our own synthetic Return must pass through untouched, or the tap would chase
        // its own tail.
        if SyntheticEvent.isOurs(event) { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.mouseEventButtonNumber) == mouseButton else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .otherMouseDown:
            guard !isDown else { return nil }      // ignore auto-repeat
            isDown = true
            postReturn(down: true)
        case .otherMouseUp:
            guard isDown else { return nil }
            isDown = false
            postReturn(down: false)
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil                                  // swallow the click itself
    }

    /// Post the Return as a real key event so the focused app cannot tell it from the
    /// keyboard. Tagged as ours so 轻语's own taps ignore it.
    private func postReturn(down: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: Self.returnKeyCode, keyDown: down) else { return }
        SyntheticEvent.mark(event)
        event.post(tap: .cghidEventTap)
    }
}
