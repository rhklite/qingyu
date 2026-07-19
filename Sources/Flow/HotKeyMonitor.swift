import Cocoa
import CoreGraphics

/// Watches a single global push-to-talk key via a listen-only CGEvent tap.
/// Reports .down / .up transitions on the main thread. A modifier key (the
/// default Right-Option, keycode 61) is recommended so the key never types a
/// character into the focused app while held.
final class HotKeyMonitor {
    enum Key { case down, up }

    private let keyCode: Int64
    private let onEvent: (Key) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(keyCode: Int, onEvent: @escaping (Key) -> Void) {
        self.keyCode = Int64(keyCode)
        self.onEvent = onEvent
    }

    /// Returns false if the tap could not be created (missing Input Monitoring permission).
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)

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

    // Runs on the main run loop (the tap source is attached there).
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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
