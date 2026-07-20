import Cocoa

/// A tiny modal panel that captures the next key or modifier the user presses, so the
/// push-to-talk key can be rebound from inside the app. Returns the CGKeyCode (nil if
/// the user pressed Esc to cancel).
@MainActor
final class HotkeyCapture {
    private var window: NSWindow?
    private var monitor: Any?
    private var onResult: ((Int?) -> Void)?

    func begin(onResult: @escaping (Int?) -> Void) {
        guard window == nil else { return }
        self.onResult = onResult

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Set Push-to-Talk Key"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()

        let label = NSTextField(wrappingLabelWithString:
            "Press the key you want to hold to talk.\nA modifier (⌥ ⌃ ⌘ ⇧) is recommended so it never types.\n\nEsc to cancel.")
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.frame = NSRect(x: 20, y: 15, width: 340, height: 100)
        w.contentView?.addSubview(label)

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil   // swallow — don't let the captured key act on anything
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { finish(nil); return }   // Esc → cancel
            finish(Int(event.keyCode))
            return
        }
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
