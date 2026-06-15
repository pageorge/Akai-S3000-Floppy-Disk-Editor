#!/usr/bin/env swift
import AppKit
import CoreGraphics

let red = NSColor(red: 0.91, green: 0, blue: 0.11, alpha: 1)
let dark = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    let s = size
    let pad = s * 0.06
    let r = s * 0.18

    // Background
    let bgPath = NSBezierPath(roundedRect: NSRect(x: pad, y: pad, width: s-pad*2, height: s-pad*2), xRadius: r, yRadius: r)
    dark.setFill(); bgPath.fill()

    // Red border bars
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: pad, y: s-pad-s*0.035, width: s-pad*2, height: s*0.035), xRadius: s*0.015, yRadius: s*0.015).fill()
    NSBezierPath(roundedRect: NSRect(x: pad, y: pad, width: s-pad*2, height: s*0.035), xRadius: s*0.015, yRadius: s*0.015).fill()
    NSBezierPath(roundedRect: NSRect(x: pad, y: pad, width: s*0.035, height: s-pad*2), xRadius: s*0.015, yRadius: s*0.015).fill()
    NSBezierPath(roundedRect: NSRect(x: s-pad-s*0.035, y: pad, width: s*0.035, height: s-pad*2), xRadius: s*0.015, yRadius: s*0.015).fill()

    // Floppy disk (left side)
    let fx = s * 0.15, fy = s * 0.18, fw = s * 0.22, fh = s * 0.28
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: fx, y: fy, width: fw, height: fh), xRadius: s*0.02, yRadius: s*0.02).fill()
    NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.08, y: fy+fh*0.56, width: fw*0.84, height: fh*0.36), xRadius: s*0.01, yRadius: s*0.01).fill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.25, y: fy+fh*0.08, width: fw*0.5, height: fh*0.07), xRadius: s*0.008, yRadius: s*0.008).fill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.38, y: fy+fh*0.62, width: fw*0.24, height: fw*0.24)).fill()
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.44, y: fy+fh*0.68, width: fw*0.12, height: fw*0.12)).fill()

    // AKAI text
    let fontSize = s * 0.28
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: NSColor.white
    ]
    let akaiStr = NSAttributedString(string: "AKAI", attributes: attrs)
    akaiStr.draw(at: NSPoint(x: s*0.42, y: s*0.48))

    // S3000 text
    let fontSize2 = s * 0.14
    let attrs2: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: fontSize2),
        .foregroundColor: red
    ]
    let s3000Str = NSAttributedString(string: "S3000", attributes: attrs2)
    s3000Str.draw(at: NSPoint(x: s*0.42, y: s*0.34))

    // Waveform
    let wavePoints: [(CGFloat, CGFloat)] = [
        (0.12,0.22),(0.18,0.15),(0.24,0.25),(0.30,0.10),(0.36,0.20),
        (0.42,0.06),(0.48,0.18),(0.54,0.12),(0.60,0.20),(0.66,0.14),(0.72,0.20)
    ]
    let wavePath = NSBezierPath()
    wavePath.lineWidth = s * 0.018
    wavePath.lineCapStyle = .round
    wavePath.lineJoinStyle = .round
    let baseY = s * 0.14
    wavePath.move(to: NSPoint(x: s*0.14, y: baseY + s*wavePoints[0].1))
    for p in wavePoints.dropFirst() {
        wavePath.line(to: NSPoint(x: s*p.0, y: baseY + s*p.1))
    }
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
    let icon = drawIcon(size: size)
    savePNG(icon, to: "\(outputDir)/\(filename)")
}

print("Done! Copy the PNG files into AkaiS3000Editor/Assets.xcassets/AppIcon.appiconset/")
