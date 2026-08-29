import Cocoa

/// The "「Dragon」 is now in your dictionary" notice that takes the speech bar's place
/// after a dictation that turned up a new term.
///
/// The term is added first and this offers to take it back, rather than asking
/// permission — dictation is a flow activity and a question mid-flow is a tax. The
/// shrinking bar is the deadline: when it runs out the term simply stays.
@MainActor
final class JargonToast {
    private var panel: NSPanel?
    private var progress: CountdownView?
    private var undo: (() -> Void)?
    private var timer: Timer?
    private var deadline = Date.distantPast
    private var duration: TimeInterval = 10

    private static let size = NSSize(width: 340, height: 56)

    /// Show the notice for `term`. `onUndo` runs only if the user declines in time.
    func show(term: String, seconds: TimeInterval = 10, onUndo: @escaping () -> Void) {
        buildIfNeeded()
        guard let panel, let progress else { return }
        undo = onUndo
        duration = seconds
        deadline = Date().addingTimeInterval(seconds)

        label?.attributedStringValue = Self.message(term: term)
        progress.fraction = 1
        reposition()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        timer?.invalidate()
        // .common so the countdown keeps running while a menu is open — otherwise the
        // deadline silently freezes whenever the user pops the menu bar item.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private var label: NSTextField?

    private func tick() {
        let remaining = deadline.timeIntervalSinceNow
        progress?.fraction = max(0, min(1, remaining / duration))
        if remaining <= 0 { dismiss(undoing: false) }
    }

    @objc private func declineClicked() {
        dismiss(undoing: true)
    }

    private func dismiss(undoing: Bool) {
        timer?.invalidate(); timer = nil
        if undoing { undo?() }
        undo = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Hide without undoing — used when a new dictation starts and the speech bar needs
    /// the space back. The term keeps its place in the dictionary.
    func hide() { dismiss(undoing: false) }

    private static func message(term: String) -> NSAttributedString {
        let s = NSMutableAttributedString(
            string: "「\(term)」",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.white])
        s.append(NSAttributedString(
            string: "  added to your dictionary",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.8)]))
        return s
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let size = Self.size
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Unlike the speech bar this one must be clickable — that's the whole point.
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let text = NSTextField(labelWithString: "")
        text.frame = NSRect(x: 14, y: 20, width: size.width - 110, height: 20)
        text.lineBreakMode = .byTruncatingTail
        bg.addSubview(text)
        label = text

        let decline = NSButton(title: "No thanks", target: self, action: #selector(declineClicked))
        decline.bezelStyle = .inline
        decline.controlSize = .small
        decline.frame = NSRect(x: size.width - 92, y: 17, width: 80, height: 22)
        bg.addSubview(decline)

        let bar = CountdownView(frame: NSRect(x: 14, y: 11, width: size.width - 28, height: 3))
        bar.autoresizingMask = [.width]
        bg.addSubview(bar)
        progress = bar

        p.contentView = bg
        panel = p
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let s = panel.frame.size
        // Same spot the speech bar uses, so the notice reads as its continuation.
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - s.width / 2,
                                     y: SpeechBar.bottomY(for: screen)))
    }
}

/// A bar that shrinks from full width to nothing — the visible deadline.
private final class CountdownView: NSView {
    var fraction: CGFloat = 1 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = bounds.width * max(0, min(1, fraction))
        guard width > 0 else { return }
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
