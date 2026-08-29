import Cocoa

/// A tiny modal panel that captures the next key or modifier the user presses, so the
/// push-to-talk key can be rebound from inside the app. Returns the CGKeyCode (nil if
/// the user pressed Esc to cancel).
@MainActor
final class HotkeyCapture {
    /// Readable name for a stored CGKeyCode — the menu and the settings panel both have
    /// to show the user which key they're holding.
    static func name(for code: Int) -> String {
        if HotKeyMonitor.isMouseButton(code) {
            // Button 2 is the wheel click; the side buttons most people reach for start
            // at 3, and mouse software counts them from 1 the same way.
            return "mouse button \(HotKeyMonitor.mouseButton(from: code) + 1)"
        }
        switch code {
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        default: return "key \(code)"
        }
    }

    private var window: NSWindow?
    private var monitor: Any?
    private var onResult: ((Int?) -> Void)?

    /// Whether this capture will accept a keyboard key, or only a mouse button.
    private var mouseOnly = false

    /// - Parameter mouseOnly: reject keys and wait for a mouse button. Used by the
    ///   mouse-to-Return binding, which has nothing to do with the keyboard and would
    ///   otherwise silently accept a key it can't act on.
    func begin(mouseOnly: Bool = false, onResult: @escaping (Int?) -> Void) {
        guard window == nil else { return }
        self.onResult = onResult
        self.mouseOnly = mouseOnly

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = mouseOnly ? "Set Mouse Button" : "Set Push-to-Talk Key"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()

        let label = NSTextField(wrappingLabelWithString: mouseOnly
            ? "Click the mouse button you want to send Return, inside this window."
            + "\n\nUse a side or thumb button. Left and right click can't be bound — you'd "
            + "have no working mouse left.\n\nEsc to cancel."
            : "Press the key you want to hold to talk, or click a side button on your mouse "
            + "inside this window.\n\nA modifier (⌥ ⌃ ⌘ ⇧) or a mouse button is best — an "
            + "ordinary key types its character while you hold it.\n\nEsc to cancel.")
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.frame = NSRect(x: 20, y: 15, width: 340, height: 140)
        w.contentView?.addSubview(label)

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .otherMouseDown]
        ) { [weak self] event in
            self?.handle(event)
            return nil   // swallow — don't let the captured key act on anything
        }
    }

    private func handle(_ event: NSEvent) {
        // Extra mouse buttons only: the wheel click and the side buttons arrive as
        // otherMouseDown, while left and right click never reach this monitor, which is
        // what keeps them from being bound by accident.
        if event.type == .otherMouseDown {
            finish(HotKeyMonitor.mouseCodeBase + event.buttonNumber)
            return
        }
        if event.type == .keyDown {
            if event.keyCode == 53 { finish(nil); return }   // Esc → cancel
            guard !mouseOnly else { return }                 // ignore keys; keep waiting
            finish(Int(event.keyCode))
            return
        }
        guard !mouseOnly else { return }
        // flagsChanged: only capture on the PRESS (a modifier flag is now active),
        // not the release (flags cleared).
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !mods.isEmpty { finish(Int(event.keyCode)) }
    }

    private func finish(_ keyCode: Int?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.close()
        window = nil
        let cb = onResult
        onResult = nil
        cb?(keyCode)
    }
}
