#!/usr/bin/env swift
import AppKit

let red = NSColor(red: 0.91, green: 0, blue: 0.11, alpha: 1)
let dark = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let s = size
    let r = s * 0.18

    // Clip everything to the rounded rect
    let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: r, yRadius: r)
    clip.addClip()

    // Dark background
    dark.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()

    // Red border bars — inside the clip so corners are clean
    let bar = s * 0.05
    red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: s-bar, width: s, height: bar)).fill()  // top
    NSBezierPath(rect: NSRect(x: 0, y: 0,     width: s, height: bar)).fill()  // bottom
    NSBezierPath(rect: NSRect(x: 0, y: 0,     width: bar, height: s)).fill()  // left
    NSBezierPath(rect: NSRect(x: s-bar, y: 0, width: bar, height: s)).fill()  // right

    // Floppy disk body
    let fx = s*0.08, fy = s*0.28, fw = s*0.26, fh = s*0.34
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: fx, y: fy, width: fw, height: fh), xRadius: s*0.02, yRadius: s*0.02).fill()
    // Label area
    NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.08, y: fy+fh*0.54, width: fw*0.84, height: fh*0.38), xRadius: s*0.01, yRadius: s*0.01).fill()
    // Shutter slot
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.22, y: fy+fh*0.08, width: fw*0.56, height: fh*0.07), xRadius: s*0.005, yRadius: s*0.005).fill()
    // Hub
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.36, y: fy+fh*0.62, width: fw*0.28, height: fw*0.28)).fill()
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.43, y: fy+fh*0.69, width: fw*0.14, height: fw*0.14)).fill()

    // AKAI text — centred in right portion
    let akaiSize = s * 0.24
    let akaiAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: akaiSize),
        .foregroundColor: NSColor.white
    ]
    let akaiStr = NSAttributedString(string: "AKAI", attributes: akaiAttrs)
    let akaiW = akaiStr.size().width
    let rightStart = s * 0.38
    let rightWidth = s * 0.56
    akaiStr.draw(at: NSPoint(x: rightStart + (rightWidth - akaiW) / 2, y: s*0.52))

    // S3000 text
    let s3Size = s * 0.13
    let s3Attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: s3Size),
        .foregroundColor: red
    ]
    let s3Str = NSAttributedString(string: "S3000", attributes: s3Attrs)
    let s3W = s3Str.size().width
    s3Str.draw(at: NSPoint(x: rightStart + (rightWidth - s3W) / 2, y: s*0.37))

    // Waveform along bottom
    let wavePath = NSBezierPath()
    wavePath.lineWidth = max(1, s * 0.016)
    wavePath.lineCapStyle = .round
    wavePath.lineJoinStyle = .round
    let pts: [(CGFloat,CGFloat)] = [
        (0.08,0.20),(0.17,0.11),(0.26,0.22),(0.35,0.07),(0.44,0.18),
        (0.53,0.04),(0.62,0.15),(0.71,0.09),(0.80,0.17),(0.90,0.11)
    ]
    wavePath.move(to: NSPoint(x: s*pts[0].0, y: s*pts[0].1))
    for p in pts.dropFirst() { wavePath.line(to: NSPoint(x: s*p.0, y: s*p.1)) }
    red.withAlphaComponent(0.7).setStroke()
    wavePath.stroke()

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
