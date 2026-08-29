import Cocoa

/// Inserts transcribed text into whatever app currently has keyboard focus.
/// "paste" clobbers-then-restores the clipboard and sends ⌘V (fast, reliable for
/// long text). "type" synthesizes Unicode key events (leaves the clipboard alone).
/// Both require Accessibility permission to post events.
enum TextInjector {
    enum Result {
        case injected        // pasted / typed straight into the focused app
        case clipboardOnly   // left on the clipboard for the user to ⌘V themselves
    }

    @discardableResult
    static func inject(_ text: String, mode: String) -> Result {
        guard !text.isEmpty else { return .injected }

        // Posting synthetic key events needs Accessibility, which lives in the
        // root-owned system TCC database — a standard (non-admin) user simply can't
        // grant it. Silently doing nothing would look like the app is broken, so fall
        // back to leaving the text on the clipboard: ⌘V still works, by hand.
        guard Permissions.accessibilityGranted || Permissions.postEventGranted else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .clipboardOnly
        }

        if mode == "type" {
            typeUnicode(text)
        } else {
            paste(text)
        }
        return .injected
    }

    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)

        pb.clearContents()
        let ours = pb.setString(text, forType: .string) ? pb.changeCount : -1
        sendCommandV()

        // Restore the user's prior clipboard once the paste has been delivered.
        //
        // Two ways this used to go wrong, both of which put the *old* clipboard on
        // screen instead of the dictation — a stale URL pasted into a chat box:
        //
        //  - restoring too early, before the focused app had consumed the ⌘V, so what
        //    it eventually read was the restored value. A busy or slow app needs more
        //    than a third of a second.
        //  - restoring over something the user copied in the meantime, which the
        //    changeCount check now catches: if the clipboard is no longer ours, it
        //    isn't ours to put back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard pb.changeCount == ours else { return }   // someone else owns it now
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
        // Tagged so the push-to-talk tap skips them: with ⌘ as the talk key, an untagged
        // ⌘V would read as another press and start dictating again.
        SyntheticEvent.mark(down)
        SyntheticEvent.mark(up)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            SyntheticEvent.mark(down)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            SyntheticEvent.mark(up)
            up?.post(tap: .cghidEventTap)
        }
    }
}
