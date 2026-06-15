#!/usr/bin/env swift
import AppKit

let red = NSColor(red: 0.91, green: 0, blue: 0.11, alpha: 1)
let dark = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let s = size
    let r = s * 0.18  // corner radius

    // Background fills entire canvas
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: r, yRadius: r)
    dark.setFill(); bgPath.fill()

    // Red border bars — thin, hugging edges
    let bar = s * 0.04
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: s-bar, width: s, height: bar), xRadius: r, yRadius: r).fill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: bar), xRadius: r, yRadius: r).fill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bar, height: s), xRadius: r, yRadius: r).fill()
    NSBezierPath(roundedRect: NSRect(x: s-bar, y: 0, width: bar, height: s), xRadius: r, yRadius: r).fill()

    // Floppy disk — left side, larger
    let fx = s*0.06, fy = s*0.22, fw = s*0.28, fh = s*0.34
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: fx, y: fy, width: fw, height: fh), xRadius: s*0.02, yRadius: s*0.02).fill()
    NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.08, y: fy+fh*0.54, width: fw*0.84, height: fh*0.38), xRadius: s*0.01, yRadius: s*0.01).fill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.28, y: fy+fh*0.1, width: fw*0.44, height: fh*0.06), xRadius: s*0.005, yRadius: s*0.005).fill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.36, y: fy+fh*0.62, width: fw*0.28, height: fw*0.28)).fill()
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.43, y: fy+fh*0.69, width: fw*0.14, height: fw*0.14)).fill()

    // Waveform in floppy label area
    let wavePath = NSBezierPath()
    wavePath.lineWidth = max(1, s * 0.015)
    wavePath.lineCapStyle = .round
    wavePath.lineJoinStyle = .round
    let wpts: [(CGFloat,CGFloat)] = [(0.08,0.36),(0.12,0.28),(0.16,0.40),(0.20,0.24),(0.24,0.36),(0.28,0.20),(0.32,0.32),(0.36,0.26),(0.40,0.36)]
    wavePath.move(to: NSPoint(x: fx + fw*wpts[0].0, y: fy + fh*wpts[0].1))
    for p in wpts.dropFirst() { wavePath.line(to: NSPoint(x: fx + fw*p.0, y: fy + fh*p.1)) }
    NSColor.white.withAlphaComponent(0.6).setStroke()
    wavePath.stroke()

    // AKAI text — large, bold
    let akaiSize = s * 0.32
    let akaiAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: akaiSize),
        .foregroundColor: NSColor.white
    ]
    NSAttributedString(string: "AKAI", attributes: akaiAttrs).draw(at: NSPoint(x: s*0.38, y: s*0.50))

    // S3000 text
    let s3Size = s * 0.155
    let s3Attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: s3Size),
        .foregroundColor: red
    ]
    NSAttributedString(string: "S3000", attributes: s3Attrs).draw(at: NSPoint(x: s*0.38, y: s*0.34))

    // Bottom waveform decoration
    let waveDecor = NSBezierPath()
    waveDecor.lineWidth = max(1, s * 0.016)
    waveDecor.lineCapStyle = .round
    waveDecor.lineJoinStyle = .round
    let dpts: [(CGFloat,CGFloat)] = [
        (0.08,0.18),(0.16,0.10),(0.24,0.20),(0.32,0.06),(0.40,0.16),
        (0.48,0.02),(0.56,0.14),(0.64,0.08),(0.72,0.16),(0.80,0.10),(0.90,0.16)
    ]
    waveDecor.move(to: NSPoint(x: s*dpts[0].0, y: s*dpts[0].1))
    for p in dpts.dropFirst() { waveDecor.line(to: NSPoint(x: s*p.0, y: s*p.1)) }
    red.withAlphaComponent(0.65).setStroke()
    waveDecor.stroke()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("Saved: \(path)")
}

let sizes: [(CGFloat, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

for (size, filename) in sizes {
    savePNG(drawIcon(size: size), to: "\(outputDir)/\(filename)")
}
print("Done!")
