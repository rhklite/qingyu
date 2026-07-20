import Cocoa

/// Inserts transcribed text into whatever app currently has keyboard focus.
/// "paste" clobbers-then-restores the clipboard and sends ⌘V (fast, reliable for
/// long text). "type" synthesizes Unicode key events (leaves the clipboard alone).
/// Both require Accessibility permission to post events.
enum TextInjector {
    static func inject(_ text: String, mode: String) {
        guard !text.isEmpty else { return }
        if mode == "type" {
            typeUnicode(text)
        } else {
            paste(text)
        }
    }

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)
        sendCommandV()

        // Restore the user's prior clipboard once the paste has been delivered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pb.clearContents()
            if let previous { pb.setString(previous, forType: .string) }
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09   // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.post(tap: .cghidEventTap)
        }
    }
}
