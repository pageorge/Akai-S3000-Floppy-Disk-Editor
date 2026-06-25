import SwiftUI

// MARK: - Drag mode

enum PianoDragMode {
    case none, lowKey, highKey, rootKey
}

// MARK: - Piano Keyboard View

struct PianoKeyboardView: View {
    let keyzones: [AkaiProgramKeyzone]
    let selectedIndex: Int?
    var onKeyzoneChanged: ((AkaiProgramKeyzone) -> Void)? = nil

    /// The full visible key range of this keyboard. Used elsewhere (e.g. a new
    /// keyzone's default high key) so "the max key you can see" always matches
    /// what's actually rendered here, with no separate constant to drift out of sync.
    static let visibleStartNote = 24
    static let visibleEndNote   = 95

    private let startNote: Int = PianoKeyboardView.visibleStartNote
    private let endNote: Int   = PianoKeyboardView.visibleEndNote
    private let blackKeyPattern = [1, 3, 6, 8, 10]

    @State private var dragMode: PianoDragMode = .none
    @State private var hoveredNote: Int? = nil

    private var selectedZone: AkaiProgramKeyzone? {
        guard let idx = selectedIndex, idx < keyzones.count else { return nil }
        return keyzones[idx]
    }
    private var lowKey:  Int { Int(selectedZone?.lowKey  ?? 0) }
    private var highKey: Int { Int(selectedZone?.highKey ?? 0) }
    private var rootKey: Int { Int(selectedZone?.rootNote ?? 0) }

    private func keyRole(_ note: Int) -> KeyRole {
        guard selectedZone != nil else { return .normal }
        if note == rootKey { return .root }
        if note == lowKey  { return .low }
        if note == highKey { return .high }
        if note >= lowKey && note <= highKey { return .inRange }
        return .normal
    }

    var body: some View {
        GeometryReader { geo in
            let whiteKeyCount  = countWhiteKeys(from: startNote, to: endNote)
            let whiteKeyWidth  = geo.size.width / CGFloat(whiteKeyCount)
            let whiteKeyHeight = geo.size.height
            let blackKeyWidth  = whiteKeyWidth * 0.6
            let blackKeyHeight = whiteKeyHeight * 0.70
            let whitePositions = computeWhitePositions(whiteKeyWidth: whiteKeyWidth)

            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 0) {
                    ForEach(startNote...endNote, id: \.self) { note in
                        if isWhiteKey(note) {
                            WhitePianoKey(
                                note: note,
                                role: keyRole(note),
                                isHovered: hoveredNote == note && selectedZone != nil
                            )
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                        }
                    }
                }

                // Black keys
                ForEach(startNote...endNote, id: \.self) { note in
                    if !isWhiteKey(note) {
                        let prevWhiteX = whitePositions[note - 1] ?? 0
                        BlackPianoKey(
                            note: note,
                            role: keyRole(note),
                            isHovered: hoveredNote == note && selectedZone != nil
                        )
                        .frame(width: blackKeyWidth, height: blackKeyHeight)
                        .offset(x: prevWhiteX + whiteKeyWidth - blackKeyWidth / 2)
                    }
                }

                // Note labels
                ForEach([24,36,48,60,72,84,96,108].filter { $0 >= startNote && $0 <= endNote }, id: \.self) { note in
                    let x = xPositionForNote(note, whiteKeyWidth: whiteKeyWidth)
                    Text("C\(note/12 - 1)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(x: x + 1, y: whiteKeyHeight - 14)
                }

                // Legend
                if selectedZone != nil {
                    HStack(spacing: 10) {
                        LegendDot(color: .green,  label: "Range")
                        LegendDot(color: Color(red: 1.0, green: 0.6, blue: 0.6), label: "Low")
                        LegendDot(color: Color(red: 0.6, green: 0.75, blue: 1.0), label: "High")
                        LegendDot(color: .orange, label: "Root")
                    }
                    .padding(4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: geo.size.width - 210, y: 4)
                }

                // Drag/hover tooltip
                if let note = hoveredNote, selectedZone != nil {
                    let x = min(xPositionForNote(note, whiteKeyWidth: whiteKeyWidth), geo.size.width - 80)
                    Text(midiNoteName(UInt8(note)))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .offset(x: x, y: 2)
                }

                // Transparent drag/hover capture overlay
                if selectedZone != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let note = noteForX(value.location.x, whiteKeyWidth: whiteKeyWidth,
                                                        totalWidth: geo.size.width,
                                                        whitePositions: whitePositions,
                                                        blackKeyWidth: blackKeyWidth,
                                                        blackKeyHeight: blackKeyHeight,
                                                        y: value.location.y,
                                                        whiteKeyHeight: whiteKeyHeight)
                                    hoveredNote = note
                                    guard var zone = selectedZone else { return }

                                    // Determine drag mode on first touch
                                    if dragMode == .none {
                                        let distToLow  = abs(note - lowKey)
                                        let distToHigh = abs(note - highKey)
                                        let distToRoot = abs(note - rootKey)
                                        let minDist = min(distToLow, distToHigh, distToRoot)
                                        if minDist == distToRoot && distToRoot <= 3 { dragMode = .rootKey }
                                        else if distToLow <= distToHigh              { dragMode = .lowKey  }
                                        else                                          { dragMode = .highKey }
                                    }

                                    switch dragMode {
                                    case .lowKey:
                                        zone.lowKey = UInt8(min(note, Int(zone.highKey)))
                                    case .highKey:
                                        zone.highKey = UInt8(max(note, Int(zone.lowKey)))
                                    case .rootKey:
                                        zone.rootNote = UInt8(max(0, min(note, 127)))
                                    case .none: break
                                    }
                                    onKeyzoneChanged?(zone)
                                }
                                .onEnded { _ in
                                    dragMode = .none
                                    hoveredNote = nil
                                }
                        )
                        .onHover { inside in
                            if !inside { hoveredNote = nil }
                        }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
        }
    }

    // MARK: - Hit testing

    private func noteForX(_ x: CGFloat, whiteKeyWidth: CGFloat, totalWidth: CGFloat,
                          whitePositions: [Int: CGFloat], blackKeyWidth: CGFloat,
                          blackKeyHeight: CGFloat, y: CGFloat, whiteKeyHeight: CGFloat) -> Int {
        // Check black keys first (they're on top)
        if y < whiteKeyHeight * 0.70 {
            for note in startNote...endNote where !isWhiteKey(note) {
                let prevWhiteX = whitePositions[note - 1] ?? 0
                let keyX = prevWhiteX + whiteKeyWidth - blackKeyWidth / 2
                if x >= keyX && x < keyX + blackKeyWidth {
                    return note
                }
            }
        }
        // White key
        let whiteIdx = Int(x / whiteKeyWidth)
        var count = 0
        for note in startNote...endNote where isWhiteKey(note) {
            if count == whiteIdx { return note }
            count += 1
        }
        return endNote
    }

    // MARK: - Helpers

    private func isWhiteKey(_ note: Int) -> Bool { !blackKeyPattern.contains(note % 12) }

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
            if isWhiteKey(note) { positions[note] = CGFloat(whiteCount) * whiteKeyWidth; whiteCount += 1 }
        }
        return positions
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}

// MARK: - Legend

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Key Role

enum KeyRole {
    case normal, inRange, low, high, root

    var whiteColor: Color {
        switch self {
        case .normal:   return .white
        case .inRange:  return Color(red: 0.7, green: 1.0, blue: 0.7)
        case .low:      return Color(red: 1.0, green: 0.6, blue: 0.6)
        case .high:     return Color(red: 0.6, green: 0.75, blue: 1.0)
        case .root:     return Color(red: 1.0, green: 0.65, blue: 0.0)
        }
    }

    var blackColor: Color {
        switch self {
        case .normal:   return Color.black.opacity(0.85)
        case .inRange:  return Color(red: 0.0, green: 0.55, blue: 0.2)
        case .low:      return Color(red: 0.7, green: 0.1, blue: 0.1)
        case .high:     return Color(red: 0.1, green: 0.3, blue: 0.75)
        case .root:     return Color(red: 0.8, green: 0.45, blue: 0.0)
        }
    }
}

// MARK: - Key Views

struct WhitePianoKey: View {
    let note: Int
    let role: KeyRole
    let isHovered: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(isHovered ? role.whiteColor.opacity(0.7) : role.whiteColor)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            if isHovered {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 7))
                    .foregroundStyle(.black.opacity(0.5))
                    .padding(.bottom, 12)
            }
            if role == .root {
                Circle().fill(Color.orange).frame(width: 6, height: 6).padding(.bottom, 4)
            } else if role == .low {
                Circle().fill(Color(red: 1.0, green: 0.3, blue: 0.3)).frame(width: 6, height: 6).padding(.bottom, 4)
            } else if role == .high {
                Circle().fill(Color(red: 0.4, green: 0.6, blue: 1.0)).frame(width: 6, height: 6).padding(.bottom, 4)
            }
        }
    }
}

struct BlackPianoKey: View {
    let note: Int
    let role: KeyRole
    let isHovered: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(isHovered ? role.blackColor.opacity(0.7) : role.blackColor)
                .cornerRadius(2, corners: [.bottomLeft, .bottomRight])
            if role == .root {
                Circle().fill(Color.orange).frame(width: 5, height: 5).padding(.bottom, 3)
            } else if role == .low {
                Circle().fill(Color(red: 1.0, green: 0.3, blue: 0.3)).frame(width: 5, height: 5).padding(.bottom, 3)
            } else if role == .high {
                Circle().fill(Color(red: 0.4, green: 0.6, blue: 1.0)).frame(width: 5, height: 5).padding(.bottom, 3)
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
        if tr > 0 { path.addArc(center: CGPoint(x: rect.maxX-tr, y: rect.minY+tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: rect.maxX-br, y: rect.maxY-br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: rect.minX+bl, y: rect.maxY-bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: rect.minX+tl, y: rect.minY+tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        path.closeSubpath()
        return path
    }
}
