import SwiftUI

// MARK: - Piano Keyboard View (shows keyzone ranges visually)

struct PianoKeyboardView: View {
    let keyzones: [AkaiProgramKeyzone]
    let selectedIndex: Int?

    // We show 5 octaves (C1–C6, notes 24–84), 61 keys
    private let startNote: Int = 24   // C1
    private let endNote: Int = 108    // C7 — wider view
    private var totalKeys: Int { endNote - startNote + 1 }

    // Which piano notes are black keys
    private let blackKeyPattern = [1, 3, 6, 8, 10]  // offsets within octave

    var body: some View {
        GeometryReader { geo in
            let whiteKeyCount = countWhiteKeys(from: startNote, to: endNote)
            let whiteKeyWidth = geo.size.width / CGFloat(whiteKeyCount)
            let whiteKeyHeight = geo.size.height
            let blackKeyWidth = whiteKeyWidth * 0.6
            let blackKeyHeight = whiteKeyHeight * 0.62

            ZStack(alignment: .topLeading) {
                // Keyzone color bands (behind keys)
                ForEach(Array(keyzones.enumerated()), id: \.offset) { idx, kz in
                    let low = max(Int(kz.lowKey), startNote)
                    let high = min(Int(kz.highKey), endNote)
                    if low <= high {
                        let lowX = xPositionForNote(low, whiteKeyWidth: whiteKeyWidth)
                        let highX = xPositionForNote(high, whiteKeyWidth: whiteKeyWidth) + whiteKeyWidth
                        let color = keyzoneColor(idx: idx, isSelected: idx == selectedIndex)

                        Rectangle()
                            .fill(color.opacity(idx == selectedIndex ? 0.35 : 0.18))
                            .frame(width: max(0, highX - lowX), height: whiteKeyHeight)
                            .offset(x: lowX)
                    }
                }

                // White keys
                HStack(spacing: 0) {
                    ForEach(startNote...endNote, id: \.self) { note in
                        if isWhiteKey(note) {
                            WhitePianoKey(
                                note: note,
                                isRootOfAnyZone: keyzones.indices.contains(selectedIndex ?? -1) &&
                                    Int((keyzones[selectedIndex!]).rootNote) == note
                            )
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                        }
                    }
                }

                // Black keys (positioned absolutely)
                let whitePositions = computeWhitePositions(whiteKeyWidth: whiteKeyWidth)
                ForEach(startNote...endNote, id: \.self) { note in
                    if !isWhiteKey(note) {
                        let prevWhiteX = whitePositions[note - 1] ?? 0
                        BlackPianoKey(
                            note: note,
                            isRootOfAnyZone: keyzones.indices.contains(selectedIndex ?? -1) &&
                                Int((keyzones[selectedIndex!]).rootNote) == note
                        )
                        .frame(width: blackKeyWidth, height: blackKeyHeight)
                        .offset(x: prevWhiteX + whiteKeyWidth - blackKeyWidth / 2)
                    }
                }

                // Root note marker triangle for selected zone
                if let idx = selectedIndex, idx < keyzones.count {
                    let root = Int(keyzones[idx].rootNote)
                    if root >= startNote && root <= endNote {
                        let x = xPositionForNote(root, whiteKeyWidth: whiteKeyWidth) + whiteKeyWidth/2
                        Triangle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: whiteKeyHeight - 10)
                    }
                }

                // Note labels every octave (C notes)
                ForEach([24, 36, 48, 60, 72, 84, 96, 108].filter { $0 >= startNote && $0 <= endNote }, id: \.self) { note in
                    let x = xPositionForNote(note, whiteKeyWidth: whiteKeyWidth)
                    Text("C\(note/12 - 1)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(x: x + 1, y: whiteKeyHeight - 14)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
        }
    }

    private func isWhiteKey(_ note: Int) -> Bool {
        let offset = note % 12
        return !blackKeyPattern.contains(offset)
    }

    private func countWhiteKeys(from: Int, to: Int) -> Int {
        (from...to).filter { isWhiteKey($0) }.count
    }

    private func xPositionForNote(_ note: Int, whiteKeyWidth: CGFloat) -> CGFloat {
        let whitesBefore = (startNote...note).filter { isWhiteKey($0) }.count
        if isWhiteKey(note) {
            return CGFloat(whitesBefore - 1) * whiteKeyWidth
        } else {
            return CGFloat(whitesBefore - 1) * whiteKeyWidth
        }
    }

    private func computeWhitePositions(whiteKeyWidth: CGFloat) -> [Int: CGFloat] {
        var positions: [Int: CGFloat] = [:]
        var whiteCount = 0
        for note in startNote...endNote {
            if isWhiteKey(note) {
                positions[note] = CGFloat(whiteCount) * whiteKeyWidth
                whiteCount += 1
            }
        }
        return positions
    }

    private func keyzoneColor(idx: Int, isSelected: Bool) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red]
        return colors[idx % colors.count]
    }
}

struct WhitePianoKey: View {
    let note: Int
    let isRootOfAnyZone: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            if isRootOfAnyZone {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .padding(.bottom, 4)
            }
        }
    }
}

struct BlackPianoKey: View {
    let note: Int
    let isRootOfAnyZone: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .controlDarkShadowColor))
                .cornerRadius(2, corners: [.bottomLeft, .bottomRight])
            if isRootOfAnyZone {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 3)
            }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let all: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        path.closeSubpath()
        return path
    }
}
