#!/usr/bin/env swift
import AppKit

let red = NSColor(red: 0.91, green: 0, blue: 0.11, alpha: 1)
let dark = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let s = size
    let r = s * 0.22  // outer corner radius, macOS-style
    let border = s * 0.035

    let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: r, yRadius: r)
    clip.addClip()

    // Red fills entire canvas = border colour
    red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()

    // Dark inset rect with proportionally-reduced corner radius so the border
    // reads as the same visual thickness all the way round, including the corners
    let inset = border
    let innerRadius = max(0, r - inset)
    dark.setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2),
                 xRadius: innerRadius, yRadius: innerRadius).fill()

    // Floppy disk
    let fx = s*0.10, fy = s*0.24, fw = s*0.26, fh = s*0.34
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: fx, y: fy, width: fw, height: fh), xRadius: s*0.02, yRadius: s*0.02).fill()
    NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.08, y: fy+fh*0.54, width: fw*0.84, height: fh*0.38), xRadius: s*0.01, yRadius: s*0.01).fill()
    NSBezierPath(roundedRect: NSRect(x: fx+fw*0.22, y: fy+fh*0.08, width: fw*0.56, height: fh*0.07), xRadius: s*0.005, yRadius: s*0.005).fill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.36, y: fy+fh*0.62, width: fw*0.28, height: fw*0.28)).fill()
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: fx+fw*0.43, y: fy+fh*0.69, width: fw*0.14, height: fw*0.14)).fill()

    let rightStart = s * 0.40, rightWidth = s * 0.52

    // AKAI text
    let akaiAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: s * 0.22),
        .foregroundColor: NSColor.white
    ]
    let akaiStr = NSAttributedString(string: "AKAI", attributes: akaiAttrs)
    akaiStr.draw(at: NSPoint(x: rightStart + (rightWidth - akaiStr.size().width) / 2, y: s*0.56))

    // S3000 on its own line
    let s3Attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: s * 0.13),
        .foregroundColor: red
    ]
    let s3Str = NSAttributedString(string: "S3000", attributes: s3Attrs)
    s3Str.draw(at: NSPoint(x: rightStart + (rightWidth - s3Str.size().width) / 2, y: s*0.40))

    // EDITOR underneath, letter-spaced, moved down a touch more
    let editorAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: s * 0.075),
        .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        .kern: s * 0.012
    ]
    let editorStr = NSAttributedString(string: "EDITOR", attributes: editorAttrs)
    editorStr.draw(at: NSPoint(x: rightStart + (rightWidth - editorStr.size().width) / 2, y: s*0.30))

    // Waveform along bottom
    let wavePath = NSBezierPath()
    wavePath.lineWidth = max(1, s * 0.016)
    wavePath.lineCapStyle = .round
    wavePath.lineJoinStyle = .round
    let pts: [(CGFloat,CGFloat)] = [
        (0.10,0.16),(0.19,0.09),(0.28,0.17),(0.37,0.05),(0.46,0.14),
        (0.55,0.03),(0.64,0.12),(0.73,0.07),(0.82,0.13),(0.90,0.09)
    ]
    wavePath.move(to: NSPoint(x: s*pts[0].0, y: s*pts[0].1))
    for p in pts.dropFirst() { wavePath.line(to: NSPoint(x: s*p.0, y: s*p.1)) }
    red.withAlphaComponent(0.8).setStroke()
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

for (size, filename) in sizes { savePNG(drawIcon(size: size), to: "\(outputDir)/\(filename)") }
print("Done!")
