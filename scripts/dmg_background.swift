// Draws the picture that sits behind the icons in the DMG window: title, an arrow
// pointing from 轻语.app at the Applications alias, and a rule separating the two
// install icons from the READ ME file below them.
//
// Usage: swift scripts/dmg_background.swift out.png out@2x.png
//
// The coordinates here are the same ones makedmg.sh feeds to Finder (top-left origin,
// 640×480 points), so moving an icon means moving the matching number in both files.
import AppKit

let W: CGFloat = 640
// Taller than the 440pt window content it sits behind: Finder anchors the picture at the
// top left and paints nothing past its edge, and how much content a window of a given
// height gets depends on whether the recipient has Finder's path bar switched on. The
// slack below y=440 is plain gradient, so either way the window is fully painted.
let H: CGFloat = 560

// Finder positions icons by their centre, in a top-left origin space; Core Graphics
// draws from the bottom left. flip() converts one to the other.
func flip(_ top: CGFloat) -> CGFloat { H - top }

func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha)
}

func text(_ string: String, font: NSFont, color: NSColor, centerX: CGFloat, topY: CGFloat) {
    let drawn = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let size = drawn.size()
    drawn.draw(at: NSPoint(x: centerX - size.width / 2, y: flip(topY) - size.height))
}

/// Left-aligned, for the numbered steps — centring them would leave the numbers ragged.
func text(_ string: String, font: NSFont, color: NSColor, leftX: CGFloat, topY: CGFloat) {
    let drawn = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    drawn.draw(at: NSPoint(x: leftX, y: flip(topY) - drawn.size().height))
}

let iconCenterY: CGFloat = 190      // centre of 轻语.app and Applications
let appX: CGFloat = 170
let applicationsX: CGFloat = 470

func drawBackground() {
    NSGradient(colors: [hex(0xE9EFF7), hex(0xFFFFFF)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    text("轻语", font: .systemFont(ofSize: 28, weight: .semibold),
         color: hex(0x2F3742), centerX: W / 2, topY: 30)
    text("拖到 Applications 安装  ·  Drag 轻语 onto Applications",
         font: .systemFont(ofSize: 13, weight: .regular),
         color: hex(0x77808F), centerX: W / 2, topY: 70)

    // Arrow drawn as one polygon rather than a shaft plus a head, so the translucent
    // fill has no seam where the two would overlap.
    let tail: CGFloat = 262, tip: CGFloat = 380, headW: CGFloat = 36
    let shaft: CGFloat = 8, barb: CGFloat = 21
    let arrow = NSBezierPath()
    let corners: [(CGFloat, CGFloat)] = [
        (tail, iconCenterY - shaft), (tip - headW, iconCenterY - shaft),
        (tip - headW, iconCenterY - barb), (tip, iconCenterY),
        (tip - headW, iconCenterY + barb), (tip - headW, iconCenterY + shaft),
        (tail, iconCenterY + shaft),
    ]
    for (i, c) in corners.enumerated() {
        let p = NSPoint(x: c.0, y: flip(c.1))
        i == 0 ? arrow.move(to: p) : arrow.line(to: p)
    }
    arrow.close()
    hex(0xA6B2C4).setFill()
    arrow.fill()

    // Gatekeeper refuses the first launch of any build that isn't notarised, and the
    // wording it uses ("Apple could not verify 轻语 is free of malware") reads like a virus
    // warning rather than a signing formality. Naming the exact buttons has to happen
    // somewhere the recipient sees before that dialog appears, and the window is the only
    // such place — an instructions file in here gets ignored.
    let rule = NSBezierPath(rect: NSRect(x: 60, y: flip(296), width: W - 120, height: 1))
    hex(0xDDE3EC).setFill()
    rule.fill()

    text("macOS will block the first launch — it does this to every app not sold through the "
         + "App Store.", font: .systemFont(ofSize: 11.5, weight: .semibold),
         color: hex(0x6B7482), centerX: W / 2, topY: 312)

    let steps = [
        "1.  Double-click 轻语 in Applications, then click Done on the warning.",
        "2.  Open System Settings › Privacy & Security, and scroll down to Security.",
        "3.  Click “Open Anyway” next to 轻语, then confirm with Open.",
    ]
    for (i, step) in steps.enumerated() {
        text(step, font: .systemFont(ofSize: 11.5, weight: .regular),
             color: hex(0x8A93A1), leftX: 96, topY: 340 + CGFloat(i) * 21)
    }

    text("首次打开：双击后按「完成」，再到 系统设置 › 隐私与安全性 › 仍要打开",
         font: .systemFont(ofSize: 11.5, weight: .regular),
         color: hex(0x99A1AE), centerX: W / 2, topY: 414)
}

func write(scale: CGFloat, to path: String) {
    let px = Int(W * scale), py = Int(H * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write(Data("cannot create \(px)×\(py) bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: W, height: H)   // makes the rep @2x rather than 1280 pt wide
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch {
        FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8))
        exit(1)
    }
}

// Text layout wants AppKit initialised even though nothing is ever shown.
_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: dmg_background.swift out.png out@2x.png\n".utf8))
    exit(2)
}
write(scale: 1, to: args[1])
write(scale: 2, to: args[2])
