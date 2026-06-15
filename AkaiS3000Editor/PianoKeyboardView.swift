import SwiftUI

// MARK: - Piano Keyboard View

struct PianoKeyboardView: View {
    let keyzones: [AkaiProgramKeyzone]
    let selectedIndex: Int?

    private let startNote: Int = 24   // C1
    private let endNote: Int = 108    // C8
    private let blackKeyPattern = [1, 3, 6, 8, 10]

    // For the selected keyzone, work out which notes are low, high, range, root
    private var selectedZone: AkaiProgramKeyzone? {
        guard let idx = selectedIndex, idx < keyzones.count else { return nil }
        return keyzones[idx]
    }
    private var lowKey:  Int { Int(selectedZone?.lowKey  ?? 0) }
    private var highKey: Int { Int(selectedZone?.highKey ?? 0) }
    private var rootKey: Int { Int(selectedZone?.rootNote ?? 0) }

    // Colour for a given note
    // root = orange, low/high boundaries = red, in-range = green, out = normal
    private func keyRole(_ note: Int) -> KeyRole {
        guard selectedZone != nil else { return .normal }
        if note == rootKey { return .root }
        if note == lowKey || note == highKey { return .boundary }
        if note >= lowKey && note <= highKey { return .inRange }
        return .normal
    }

    var body: some View {
        GeometryReader { geo in
            let whiteKeyCount = countWhiteKeys(from: startNote, to: endNote)
            let whiteKeyWidth = geo.size.width / CGFloat(whiteKeyCount)
            let whiteKeyHeight = geo.size.height
            let blackKeyWidth = whiteKeyWidth * 0.6
            let blackKeyHeight = whiteKeyHeight * 0.62
            let whitePositions = computeWhitePositions(whiteKeyWidth: whiteKeyWidth)

            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 0) {
                    ForEach(startNote...endNote, id: \.self) { note in
                        if isWhiteKey(note) {
                            WhitePianoKey(note: note, role: keyRole(note))
                                .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                        }
                    }
                }

                // Black keys
                ForEach(startNote...endNote, id: \.self) { note in
                    if !isWhiteKey(note) {
                        let prevWhiteX = whitePositions[note - 1] ?? 0
                        BlackPianoKey(note: note, role: keyRole(note))
                            .frame(width: blackKeyWidth, height: blackKeyHeight)
                            .offset(x: prevWhiteX + whiteKeyWidth - blackKeyWidth / 2)
                    }
                }

                // Note labels at C notes
                ForEach([24,36,48,60,72,84,96,108].filter { $0 >= startNote && $0 <= endNote }, id: \.self) { note in
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
        !blackKeyPattern.contains(note % 12)
    }

    private func countWhiteKeys(from: Int, to: Int) -> Int {
        (from...to).filter { isWhiteKey($0) }.count
    }

    private func xPositionForNote(_ note: Int, whiteKeyWidth: CGFloat) -> CGFloat {
        let whitesBefore = (startNote...note).filter { isWhiteKey($0) }.count
        return CGFloat(whitesBefore - 1) * whiteKeyWidth
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
}

// MARK: - Key Role

enum KeyRole {
    case normal, inRange, boundary, root

    var whiteColor: Color {
        switch self {
        case .normal:   return .white
        case .inRange:  return Color(red: 0.7, green: 1.0, blue: 0.7)   // light green
        case .boundary: return Color(red: 1.0, green: 0.6, blue: 0.6)   // light red
        case .root:     return Color(red: 1.0, green: 0.65, blue: 0.0)  // orange
        }
    }

    var blackColor: Color {
        switch self {
        case .normal:   return Color.black.opacity(0.85)
        case .inRange:  return Color(red: 0.0, green: 0.55, blue: 0.2)  // dark green
        case .boundary: return Color(red: 0.7, green: 0.1, blue: 0.1)   // dark red
        case .root:     return Color(red: 0.8, green: 0.45, blue: 0.0)  // dark orange
        }
    }
}

// MARK: - Key Views

struct WhitePianoKey: View {
    let note: Int
    let role: KeyRole

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(role.whiteColor)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            if role == .root {
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
    let role: KeyRole

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(role.blackColor)
                .cornerRadius(2, corners: [.bottomLeft, .bottomRight])
            if role == .root {
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
    static let topLeft     = RectCorner(rawValue: 1 << 0)
    static let topRight    = RectCorner(rawValue: 1 << 1)
    static let bottomLeft  = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let all: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft)     ? radius : 0
        let tr = corners.contains(.topRight)    ? radius : 0
        let bl = corners.contains(.bottomLeft)  ? radius : 0
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
