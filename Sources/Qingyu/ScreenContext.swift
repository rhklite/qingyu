import AppKit
import ApplicationServices

/// Reads the text before the cursor in the focused text field, so whisper can be primed
/// with what the user is in the middle of writing — names and terms already on screen
/// are the ones most likely to be spoken next. Uses the Accessibility permission 轻语
/// already holds for pasting. Anything that doesn't expose its text yields "".
enum ScreenContext {
    /// More than whisper's prompt budget can use; WhisperEngine trims it to tokens.
    static let maxChars = 600

    /// Blocking Accessibility calls; run off the main thread.
    static func textBeforeCursor() -> String {
        guard AXIsProcessTrusted() else { return "" }
        let system = AXUIElementCreateSystemWide()
        // A hung app must not stall dictation: on the system-wide element this sets the
        // timeout for every element we touch.
        AXUIElementSetMessagingTimeout(system, 0.25)

        // Electron apps (VS Code, Slack, Lark) build their accessibility tree only when
        // an assistive app asks for it; other apps ignore the attribute.
        if let app = NSWorkspace.shared.frontmostApplication {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        guard let focused = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "" }
        let element = focused as! AXUIElement
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            return ""
        }
        guard let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty else {
            return ""
        }

        // Cut at the cursor (the selection's start); without one, use the whole value.
        let text = value as NSString
        var end = text.length
        if let raw = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) {
                end = min(end, max(0, range.location))
            }
        }
        let start = max(0, end - maxChars)
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
