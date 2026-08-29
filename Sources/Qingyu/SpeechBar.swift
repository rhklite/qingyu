import Cocoa

/// A small floating "speech bar": a translucent pill that appears
/// at the bottom of the screen while you dictate, with a status dot and a waveform
/// meter that reacts to your voice, then a traveling shimmer while the transcript is
/// being processed. It's a non-activating panel with mouse events disabled, so it
/// never steals focus or clicks from the app you're dictating into.
@MainActor
final class SpeechBar {
    enum Mode { case listening, thinking }

    private var panel: NSPanel?
    private var meter: MeterView?
    private var generation = 0        // bumped on every show(); cancels stale teardowns

    /// Show the bar (building it lazily) in the given mode. Always forces the panel
    /// fully visible — no early-return path that could leave it stranded invisible.
    func show(mode: Mode) {
        buildIfNeeded()
        guard let panel, let meter else { return }
        generation &+= 1
        meter.mode = mode
        meter.startAnimating()
        reposition()
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = 0 }
        // ALWAYS re-present on the CURRENT Space (without activating, so focus stays on
        // the target app) — this is what makes the bar appear on whatever desktop you're
        // on, not just the one where it first showed.
        panel.orderFrontRegardless()
        if wasVisible {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Feed the live input level (0…1) to the waveform.
    func update(level: Float) {
        meter?.level = CGFloat(max(0, min(1, level)))
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }
        // Order out after the fade — unless a show() happened since (generation changed).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 230_000_000)
            guard let self, self.generation == gen else { return }
            self.meter?.stopAnimating()
            self.panel?.orderOut(nil)
        }
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let size = NSSize(width: 110, height: 28)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        // canJoinAllSpaces → appear on every desktop; fullScreenAuxiliary → over full-screen
        // apps too. (.stationary is deliberately omitted: it pins the window to its origin
        // Space and defeats canJoinAllSpaces.)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let m = MeterView(frame: bg.bounds)
        m.autoresizingMask = [.width, .height]
        bg.addSubview(m)

        p.contentView = bg
        panel = p
        meter = m
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - s.width / 2,
                                     y: SpeechBar.bottomY(for: screen)))
    }

    /// Where the floating bar sits, measured from the bottom of the usable screen —
    /// low, roughly where Wispr Flow puts its pill, rather than floating mid-screen.
    /// `overlayBottomMargin` in config.json nudges it without a rebuild.
    static var bottomMargin: CGFloat = 20

    static func bottomY(for screen: NSScreen) -> CGFloat {
        // visibleFrame already excludes the Dock, so this clears it rather than
        // hiding behind it — and still sits low when the Dock is hidden.
        screen.visibleFrame.minY + bottomMargin
    }
}

/// Draws the status dot + a centered, symmetric waveform. A 60 fps timer eases the
/// displayed level toward the latest audio level and advances a phase so the bars
/// stay alive during steady speech and shimmer while "thinking".
private final class MeterView: NSView {
    var mode: SpeechBar.Mode = .listening
    var level: CGFloat = 0            // target level from audio (listening mode)

    private var shown: CGFloat = 0    // eased, displayed level
    private var phase: CGFloat = 0
    private var timer: Timer?
    private let barCount = 7

    func startAnimating() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.shown += (self.level - self.shown) * 0.25   // ease toward target, decay on silence
            self.phase += 0.22
            self.needsDisplay = true
        }
    }

    func stopAnimating() {
        timer?.invalidate(); timer = nil
        shown = 0; phase = 0; level = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let H = b.height
        let midY = b.midY

        // Everything scales with the pill height so the layout holds at any size.
        // Status dot: red pulse while listening, steady blue while thinking.
        let dotR = H * 0.15
        let dotX = H * 0.52
        let pulse: CGFloat = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase * 1.3))
        let dotColor = (mode == .listening) ? NSColor.systemRed : NSColor.systemBlue
        dotColor.withAlphaComponent(mode == .listening ? pulse : 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX - dotR, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()

        // Waveform, centered in the space to the right of the dot.
        let barW = max(2, H * 0.12)
        let gap = H * 0.17
        let leftPad = dotX + dotR + H * 0.34
        let rightPad = H * 0.42
        let groupW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX = leftPad + max(0, (b.width - leftPad - rightPad - groupW) / 2)
        let maxH = H * 0.56
        let center = CGFloat(barCount - 1) / 2

        NSColor.white.withAlphaComponent(0.92).setFill()
        for i in 0..<barCount {
            // Taller in the middle (window), so the wave reads as a symmetric pill.
            let window = 1 - 0.55 * abs(CGFloat(i) - center) / center
            let t: CGFloat
            if mode == .listening {
                let wobble = 0.6 + 0.4 * sin(phase + CGFloat(i) * 0.7)
                t = shown * window * wobble
            } else {
                // Independent traveling shimmer while transcribing.
                t = window * (0.3 + 0.5 * (0.5 + 0.5 * sin(phase * 1.7 + CGFloat(i) * 0.9)))
            }
            let h = max(2, min(maxH, maxH * max(0.06, t)))
            let x = startX + CGFloat(i) * (barW + gap)
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
