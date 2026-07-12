import SwiftUI

// MARK: - Waveform View

struct WaveformView: View {
    let audioData: Data
    let numSamples: Int
    let loopEnabled: Bool
    let loopStart: Binding<Double>?
    let loopEnd: Binding<Double>?
    let playhead: Double
    @State private var waveformPoints: [CGFloat] = []
    /// Per-bucket signed min/max of the actual samples (normalised −1..1), so the
    /// drawn shape is the real waveform (sine looks like a sine, square like a
    /// square) rather than an absolute-value envelope.
    @State private var waveMin: [CGFloat] = []
    @State private var waveMax: [CGFloat] = []

    init(audioData: Data, numSamples: Int = 0, loopEnabled: Bool = false,
         loopStart: Binding<Double>? = nil, loopEnd: Binding<Double>? = nil,
         playhead: Double = 0) {
        self.audioData = audioData
        self.numSamples = numSamples
        self.loopEnabled = loopEnabled
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.playhead = playhead
    }

    /// The canonical sample count (slen) passed in from the header — the same
    /// value the Akai reports and the single source of truth for the waveform
    /// x-axis and loop-region scaling, so the drawn loop region matches playback.
    private var frameCount: Int {
        numSamples
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .top, endPoint: .bottom
                )

                if waveformPoints.isEmpty {
                    Text("No audio data").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                        .allowsHitTesting(false)

                    // The real waveform: one filled rectangle per bucket, from
                    // that bucket's min to its max. Drawing independent rects
                    // (rather than one closed min/max polygon) avoids any risk of
                    // self-intersecting contours cancelling out under the fill's
                    // winding rule — each bar fills unconditionally.
                    Canvas { context, size in
                        let n = min(waveMin.count, waveMax.count)
                        guard n > 0 else { return }
                        let midY = size.height / 2
                        let step = size.width / CGFloat(n)
                        func y(_ v: CGFloat) -> CGFloat { midY - v * midY }

                        var bars = Path()
                        for i in 0..<n {
                            let x = CGFloat(i) * step
                            let top = y(waveMax[i])
                            let bottom = y(waveMin[i])
                            let h = max(bottom - top, 1)   // at least 1px so silent/flat spans still show a hairline
                            bars.addRect(CGRect(x: x, y: top, width: max(step, 1), height: h))
                        }

                        context.fill(bars, with: .linearGradient(
                            Gradient(colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.5)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    .allowsHitTesting(false)

                    if loopEnabled, frameCount > 0,
                       let startBinding = loopStart, let endBinding = loopEnd {
                        let w = geo.size.width
                        let ls = min(startBinding.wrappedValue, Double(frameCount))
                        // Real playback is a simple bounded loop: S -> end of the
                        // buffer, then jump back to S. So for display we ALWAYS
                        // clamp the end to the buffer length, guaranteeing S sits
                        // left of E and the highlighted region never wraps off the
                        // right edge — matching what's actually heard.
                        let le = min(endBinding.wrappedValue, Double(frameCount))
                        let startX = CGFloat(ls / Double(frameCount)) * w
                        let endX   = CGFloat(le / Double(frameCount)) * w
                        let regionW = max(0, endX - startX)

                        Rectangle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: regionW, height: geo.size.height)
                            .offset(x: startX)
                            .allowsHitTesting(false)

                        // Loop start handle — bar on its leading edge, at loopStart.
                        LoopHandle(color: .green, label: "S", barEdge: .leading)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: startX)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / w))
                                    let newVal = frac * Double(frameCount)
                                    if newVal < endBinding.wrappedValue - 1 {
                                        startBinding.wrappedValue = newVal
                                    }
                                }
                            )

                        // Loop end handle — bar on its trailing edge, at loopEnd
                        // (clamped to the buffer length).
                        LoopHandle(color: .red, label: "E", barEdge: .trailing)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: endX - 14)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / w))
                                    let newVal = frac * Double(frameCount)
                                    if newVal > startBinding.wrappedValue + 1 {
                                        endBinding.wrappedValue = newVal
                                    }
                                }
                            )
                    }

                    if playhead > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 1.5, height: geo.size.height)
                            .offset(x: playhead * geo.size.width)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear { computeWaveform(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, newWidth in computeWaveform(width: newWidth) }
            .onChange(of: audioData) { _, _ in computeWaveform(width: geo.size.width) }
        }
    }

    private func computeWaveform(width: CGFloat) {
        guard !audioData.isEmpty else { return }
        let requestedBuckets = Int(width * 2)
        guard requestedBuckets > 0 else { return }
        let localData = audioData

        DispatchQueue.global(qos: .userInitiated).async {
            let totalFrames = localData.count / 2
            guard totalFrames > 0 else {
                DispatchQueue.main.async {
                    self.waveformPoints = []; self.waveMin = []; self.waveMax = []
                }
                return
            }
            // Never use more buckets than there are samples, otherwise most
            // buckets map to an empty fractional span (startSample==endSample)
            // and render as a flat line. For short samples (e.g. 256), one bucket
            // per sample gives the truest shape; the Shape interpolates to width.
            let buckets = min(requestedBuckets, totalFrames)
            // Spread the WHOLE sample across ALL buckets (same total-frame
            // denominator as the loop region, so they line up). For each bucket
            // capture the signed MIN and MAX sample value, so the drawn band is
            // the actual waveform shape (sine, square, saw) rather than an
            // absolute-value envelope.
            var mins: [CGFloat] = []; mins.reserveCapacity(buckets)
            var maxs: [CGFloat] = []; maxs.reserveCapacity(buckets)
            for b in 0..<buckets {
                let startSample = (b * totalFrames) / buckets
                var endSample = ((b + 1) * totalFrames) / buckets
                if endSample <= startSample { endSample = startSample + 1 }
                endSample = min(endSample, totalFrames)
                var lo: Int32 = Int32.max
                var hi: Int32 = Int32.min
                for s in startSample..<endSample {
                    let byteIdx = s * 2
                    if byteIdx + 1 < localData.count {
                        let v = Int32(Int16(bitPattern:
                            UInt16(localData[byteIdx]) | (UInt16(localData[byteIdx + 1]) << 8)))
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                    }
                }
                if lo == Int32.max { lo = 0; hi = 0 }
                mins.append(CGFloat(lo) / 32768.0)
                maxs.append(CGFloat(hi) / 32768.0)
            }

            DispatchQueue.main.async {
                self.waveMin = mins
                self.waveMax = maxs
                self.waveformPoints = maxs   // non-empty marker for the "has audio" check
            }
        }
    }
}

// MARK: - Loop Handle

struct LoopHandle: View {
    let color: Color
    let label: String
    /// Which edge the vertical bar sits on, so it lines up exactly with the
    /// loop-region highlight edge rather than the centre of the handle.
    var barEdge: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: barEdge, spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Rectangle()
                .fill(color)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 14)
        .cursor(.resizeLeftRight)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Toast

/// A transient, self-dismissing message that slides in at the bottom of the
/// view and fades out after a delay — no click needed.
struct ToastData: Equatable {
    var message: String
    var isError: Bool = false
    /// Unique token so re-showing the same text retriggers the animation/timer.
    var token = UUID()
}

struct ToastView: View {
    let data: ToastData

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: data.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(data.isError ? .orange : .green)
            Text(data.message)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

extension View {
    /// Presents a toast bound to an optional ToastData. The toast auto-dismisses
    /// after `duration` seconds by clearing the binding.
    func toast(_ toast: Binding<ToastData?>, duration: Double = 2.0) -> some View {
        modifier(ToastModifier(toast: toast, duration: duration))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: ToastData?
    let duration: Double
    @State private var workItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(data: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.token)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
            .onChange(of: toast?.token) { _, _ in
                guard toast != nil else { return }
                workItem?.cancel()
                let item = DispatchWorkItem {
                    withAnimation { toast = nil }
                }
                workItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
            }
    }
}

// MARK: - Disk Path Bar

/// A thin strip shown at the top of the app when a disk image is loaded. Shows
/// the full file path; click it to reveal the file in Finder, or use the copy
/// button to put the path on the clipboard.
struct DiskPathBar: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            // Click the path to reveal in Finder.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            // Copy path to clipboard.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy path")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Greaseweazle Log View

/// Main-window view shown while Greaseweazle is reading/writing, or after it has
/// finished (until dismissed). Shows a progress bar and a live, scrolling log.
struct GreaseweazleLogView: View {
    @ObservedObject var runner: GreaseweazleRunner

    private var title: String {
        switch runner.activity {
        case .reading: return "Reading floppy…"
        case .writing: return "Writing floppy…"
        case .idle:    return "Greaseweazle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "opticaldiscdrive.fill")
                    .font(.largeTitle).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("Drive \(runner.drive.rawValue)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.isBusy {
                    Button(role: .destructive) { runner.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { runner.clearLog() } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Full path of the file being read/written.
            if let url = runner.currentFileURL {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Progress bar: determinate if we parsed a percentage, else indeterminate.
            if let p = runner.progress {
                ProgressView(value: p) {
                    Text("\(Int(p * 100))%").font(.caption.monospaced())
                }
                .progressViewStyle(.linear)
            } else if runner.isBusy {
                ProgressView().progressViewStyle(.linear)
            }

            // Live log.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(runner.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .onChange(of: runner.logLines.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
        }
        .padding(24)
    }

    private func logColor(_ line: String) -> Color {
        if line.hasPrefix("ERROR") || line.hasPrefix("✗") { return .red }
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("$") { return .secondary }
        return .primary
    }
}

// MARK: - Info Card / Row

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            content().padding(8)
        } label: {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 2)
        }
        .padding(4)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Flow Layout

/// A simple left-to-right, top-to-bottom wrapping layout — lets pills/bubbles of
/// varying sizes pack naturally onto multiple lines (used by the program editor's
/// sample-pill bar).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, lineHeight: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += lineHeight + spacing
                x = 0; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Disk Map

/// A wide map of the whole disk: the 1600 real blocks wrapped across just 3
/// rows (instead of a tall 40-row square), full width, so each item gets far
/// more vertical room. Plain black background represents free space implicitly
/// — no grid lines, no per-block cells, no separate "free" bubble — with each
/// sample/program/volume drawn as one continuous rounded bubble merged from its
/// REAL FAT-chain run(s), positioned exactly where it physically sits. Hover
/// anywhere for exact details; names show inside a bubble when there's room.
struct DiskMapView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var hoverText: String? = nil

    private let rows = 3
    private let rowHeight: CGFloat = 34   // fixed; total map height = rowHeight * rows

    private var cols: Int {
        max(1, Int(ceil(Double(diskImage.totalBlocks) / Double(rows))))
    }

    private var usedFraction: Double {
        guard diskImage.totalBlocks > 0 else { return 0 }
        return Double(diskImage.totalBlocks - diskImage.freeBlocks) / Double(diskImage.totalBlocks)
    }

    private func color(for kind: AkaiDiskImage.DiskBlockKind) -> Color {
        switch kind {
        case .system:  return Color.secondary.opacity(0.55)
        case .free:    return Color.black
        case .sample:  return Color(red: 0.91, green: 0, blue: 0.11)
        case .program: return Color.purple
        case .multi:   return Color.teal
        }
    }

    private func name(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        switch kind {
        case .system:         return diskImage.diskName.isEmpty ? "VOLUME" : diskImage.diskName
        case .free:           return "Free Space"
        case .sample(let n):  return n
        case .program(let n): return n
        case .multi(let n):   return n
        }
    }

    private func kindLabel(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        switch kind {
        case .system:  return "Volume"
        case .free:    return "Free"
        case .sample:  return "Sample"
        case .program: return "Program"
        case .multi:   return "Multi"
        }
    }

    private func sameItem(_ a: AkaiDiskImage.DiskBlockKind, _ b: AkaiDiskImage.DiskBlockKind) -> Bool {
        switch (a, b) {
        case (.system, .system), (.free, .free): return true
        case (.sample(let n1), .sample(let n2)): return n1 == n2
        case (.program(let n1), .program(let n2)): return n1 == n2
        case (.multi(let n1), .multi(let n2)): return n1 == n2
        default: return false
        }
    }

    /// One drawable, label-able segment: a horizontal run of same-item blocks
    /// within a single row (a contiguous FAT-chain run is split at row
    /// boundaries, since the grid wraps every `cols` blocks).
    private struct Segment {
        let row: Int
        let colStart: Int
        let colSpan: Int
        let kind: AkaiDiskImage.DiskBlockKind
    }

    /// Walk the real block map and merge consecutive blocks belonging to the
    /// same sample/program/system/free run into row-segments, so a file's actual
    /// contiguous space renders as ONE continuous bubble instead of many tiny
    /// cells. Free segments are dropped — the black background already shows them.
    private func segments(from map: [AkaiDiskImage.DiskBlockKind]) -> [Segment] {
        guard !map.isEmpty else { return [] }
        let c = cols
        var result: [Segment] = []
        var i = 0
        while i < map.count {
            let kind = map[i]
            var j = i + 1
            while j < map.count, sameItem(map[j], kind) { j += 1 }
            // [i, j) is one contiguous real run — split it at row boundaries.
            if case .free = kind {
                i = j
                continue
            }
            var start = i
            while start < j {
                let row = start / c
                let rowEnd = (row + 1) * c
                let segEnd = min(j, rowEnd)
                result.append(Segment(row: row, colStart: start % c, colSpan: segEnd - start, kind: kind))
                start = segEnd
            }
            i = j
        }
        return result
    }

    var body: some View {
        // Computed ONCE per render and reused by both the bubbles and the hover
        // layer below, rather than re-walking every FAT chain on every mouse move.
        let map = diskImage.blockMap()
        let segs = segments(from: map)
        let c = cols
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk Map")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%% used", usedFraction * 100))
                    .font(.system(.title3, design: .monospaced).bold())
            }

            GeometryReader { geo in
                let cellWidth = geo.size.width / CGFloat(c)

                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black)

                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        segmentBubble(seg, cellWidth: cellWidth)
                    }

                    // Invisible hover layer on top: map pointer position back to a
                    // block index so hovering ANYWHERE (including plain black free
                    // space) shows exactly what's there. Reuses `map` computed
                    // above instead of recomputing it on every mouse-move tick.
                    Rectangle()
                        .fill(Color.clear)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let col = min(c - 1, max(0, Int(location.x / cellWidth)))
                                let row = min(rows - 1, max(0, Int(location.y / rowHeight)))
                                let idx = row * c + col
                                if idx >= 0 && idx < map.count { hoverText = detail(for: map[idx]) }
                            case .ended:
                                hoverText = nil
                            }
                        }
                }
                .frame(width: geo.size.width, height: rowHeight * CGFloat(rows), alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight * CGFloat(rows))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Hover readout (reserves its line so the layout doesn't jump).
            Text(hoverText ?? " ")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Legend.
            HStack(spacing: 16) {
                legendItem(color: Color(red: 0.91, green: 0, blue: 0.11), text: "Samples")
                legendItem(color: .purple, text: "Programs")
                legendItem(color: .teal, text: "Multis")
                legendItem(color: Color.secondary.opacity(0.55), text: "Volume / System")
                legendItem(color: .black, text: "Free")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func detail(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        "\(kindLabel(for: kind)) \u{2014} \(name(for: kind))"
    }

    /// Draw one row-segment as a continuous rounded bubble at its real position,
    /// full row height, with the item's name centred inside if there's room
    /// (otherwise just the colour — hover still gives the name).
    ///
    /// A bubble's TRUE width can be sub-pixel for tiny files (e.g. a 1-block
    /// program in a ~530-column grid), making it invisible and impossible to
    /// hover. We fudge a minimum visual width so every item is at least visible
    /// and hoverable — the hover/help text always reports the real block count,
    /// so this is purely a visibility aid, not a misrepresentation of the data.
    private let minVisualWidth: CGFloat = 10

    @ViewBuilder
    private func segmentBubble(_ seg: Segment, cellWidth: CGFloat) -> some View {
        let realWidth = CGFloat(seg.colSpan) * cellWidth
        let width = max(realWidth, minVisualWidth)
        let height = rowHeight
        // Keep the bubble's centre anchored to its real position even when
        // fudged wider, so it still reads as "roughly here" rather than drifting.
        let realX = CGFloat(seg.colStart) * cellWidth
        let x = realX - (width - realWidth) / 2
        let y = CGFloat(seg.row) * rowHeight
        let inset: CGFloat = 1.5
        let label = name(for: seg.kind)
        let canFitLabel = width > 30

        ZStack {
            RoundedRectangle(cornerRadius: min(height, width) * 0.15)
                .fill(color(for: seg.kind))
            if canFitLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: max(0, width - inset * 2), height: max(0, height - inset * 2))
        .position(x: x + width / 2, y: y + height / 2)
        .help(detail(for: seg.kind))
    }

    @ViewBuilder
    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

// MARK: - ADSR Envelope View

struct AdsrView: View {
    @Binding var attack: UInt8
    @Binding var decay: UInt8
    @Binding var sustain: UInt8
    @Binding var release: UInt8
    var color: Color = .green

    @State private var dragging: Handle? = nil

    enum Handle { case attack, decay, sustain, release }

    // Fixed layout constants — same approach as the JS reference implementation
    private let pad: CGFloat = 0
    private let yTopPad: CGFloat = 6
    private let yBotPad: CGFloat = 0

    private func calcPoints(size: CGSize) -> (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint) {
        let w = size.width - pad * 2
        let yBot = size.height - yBotPad
        let yTop = yTopPad
        let yRange = yBot - yTop

        let aFrac = CGFloat(attack)  / 99.0
        let dFrac = CGFloat(decay)   / 99.0
        let sFrac = CGFloat(sustain) / 99.0
        let rFrac = CGFloat(release) / 99.0

        // Segment widths: A/D/R are time (proportional), S is fixed (it's a level)
        let aW = aFrac * w * 0.25
        let dW = (0.05 + dFrac * 0.20) * w
        let sW = w * 0.25
        let rW = rFrac * 0.25 * w

        let x0 = pad
        let x1 = x0 + aW
        let x2 = x1 + dW
        let x3 = x2 + sW
        let x4 = x3 + rW

        let ySus = yBot - sFrac * yRange

        return (
            CGPoint(x: x0, y: yBot),   // p0: start (silence)
            CGPoint(x: x1, y: yTop),   // p1: attack peak (always full height)
            CGPoint(x: x2, y: ySus),   // p2: decay end (always at sustain level)
            CGPoint(x: x3, y: ySus),   // p3: sustain end
            CGPoint(x: x4, y: yBot)    // p4: release end (silence)
        )
    }

    // Map cursor x directly to a 0-99 value for each handle,
    // using the same geometry as calcPoints so the handle tracks the cursor exactly.
    private func xToVal(_ x: CGFloat, _ handle: Handle, _ pts: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint), _ size: CGSize) -> UInt8 {
        let w = size.width - pad * 2
        let frac: CGFloat
        switch handle {
        case .attack:
            frac = (x - pad) / (w * 0.25)
        case .decay:
            frac = (x - pts.p1.x - w * 0.05) / (w * 0.20)
        case .sustain:
            // x is actually y for sustain
            let yBot = size.height - yBotPad
            frac = (yBot - x) / (yBot - yTopPad)
        case .release:
            frac = (x - pts.p3.x) / (w * 0.25)
        }
        return UInt8(max(0, min(99, Int(frac * 99))))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = calcPoints(size: size)
            let sHandle = CGPoint(x: (pts.p2.x + pts.p3.x) / 2, y: pts.p2.y)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                    .allowsHitTesting(false)

                Canvas { ctx, cs in
                    let p = calcPoints(size: cs)

                    // Grid
                    for i in 1..<8 {
                        var line = Path()
                        let x = cs.width * CGFloat(i) / 8
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: cs.height))
                        ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    }
                    for i in 1..<4 {
                        var line = Path()
                        let y = cs.height * CGFloat(i) / 4
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: cs.width, y: y))
                        ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    }

                    // Vertical dividers between ADSR sections
                    let dividerColor = GraphicsContext.Shading.color(color.opacity(0.25))
                    for x in [p.p1.x, p.p2.x, p.p3.x] {
                        var div = Path()
                        div.move(to: CGPoint(x: x, y: 0))
                        div.addLine(to: CGPoint(x: x, y: cs.height))
                        ctx.stroke(div, with: dividerColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    // Fill
                    var fill = Path()
                    fill.move(to: p.p0)
                    fill.addLine(to: p.p1)
                    fill.addLine(to: p.p2)
                    fill.addLine(to: p.p3)
                    fill.addLine(to: p.p4)
                    fill.addLine(to: CGPoint(x: p.p4.x, y: p.p0.y))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(color.opacity(0.10)))

                    // Envelope line
                    var env = Path()
                    env.move(to: p.p0)
                    env.addLine(to: p.p1)
                    env.addLine(to: p.p2)
                    env.addLine(to: p.p3)
                    env.addLine(to: p.p4)
                    ctx.stroke(env, with: .color(color), lineWidth: 2)
                }
                .allowsHitTesting(false)

                // Segment labels with values
                let aCenter = (pts.p0.x + pts.p1.x) / 2
                let dCenter = (pts.p1.x + pts.p2.x) / 2
                let sCenter = (pts.p2.x + pts.p3.x) / 2
                let rCenter = (pts.p3.x + pts.p4.x) / 2
                let labelY = size.height / 2

                Group {
                    adsrLabel(letter: "A", value: attack, x: max(5, aCenter), y: labelY)
                    adsrLabel(letter: "D", value: decay,   x: dCenter,          y: labelY)
                    adsrLabel(letter: "S", value: sustain, x: sCenter,          y: labelY)
                    adsrLabel(letter: "R", value: release, x: release == 0 ? pts.p3.x - 5 : min(pts.p4.x - 5, rCenter), y: labelY)
                }
                .allowsHitTesting(false)

                // Handles — white dots at exact node positions
                dot(at: pts.p1,  handle: .attack,  size: size, pts: pts)
                dot(at: pts.p2,  handle: .decay,   size: size, pts: pts)
                dot(at: sHandle, handle: .sustain,  size: size, pts: pts)
                dot(at: pts.p4,  handle: .release,  size: size, pts: pts)
            }
        }
    }

    @ViewBuilder
    private func adsrLabel(letter: String, value: UInt8, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(letter)
                .foregroundStyle(Color.white)
            Text("\(value)")
                .foregroundStyle(Color.yellow)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .multilineTextAlignment(.center)
        .position(x: x, y: y)
    }

    @ViewBuilder
    private func dot(at point: CGPoint, handle: Handle, size: CGSize, pts: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint)) -> some View {
        Circle()
        .fill(Color.white)
        .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil { dragging = handle }
                        guard dragging == handle else { return }
                        // Map cursor position directly to value using same geometry
                        let v: UInt8
                        if handle == .sustain {
                            v = xToVal(value.location.y, handle, pts, size)
                        } else {
                            v = xToVal(value.location.x, handle, pts, size)
                        }
                        switch handle {
                        case .attack:  attack = v
                        case .decay:   decay = v
                        case .sustain: sustain = v
                        case .release: release = v
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
            .cursor(.pointingHand)
    }
}

/// A compact slider row matching the existing keyzone editor style.
struct EnvSlider: View {
    let label: String
    @Binding var value: UInt8
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .frame(width: 60, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(value) },
                    set: { value = UInt8($0) }
                ), in: 0...99, step: 1)
                Text("\(value)")
                    .frame(width: 30)
                    .font(.system(.body, design: .monospaced))
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 60)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DiskInfoView: View {
    @ObservedObject var diskImage: AkaiDiskImage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        // Read-only — this is an info screen, not an editor.
                        Text(diskImage.diskName.isEmpty ? "Untitled Disk" : diskImage.diskName)
                            .font(.title.bold())
                        Text("Akai S3000 Disk Image")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    DiskMapView(diskImage: diskImage)
                        .padding(.top, 4)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    InfoCard(title: "Contents") {
                        InfoRow(label: "Samples",     value: "\(diskImage.samples.count)")
                        InfoRow(label: "Programs",    value: "\(diskImage.programs.count)")
                        InfoRow(label: "Multis",      value: "\(diskImage.multis.count)")
                        InfoRow(label: "Total Files", value: "\(diskImage.samples.count + diskImage.programs.count + diskImage.multis.count)")
                    }
                    InfoCard(title: "Storage") {
                        InfoRow(label: "Total Blocks", value: "\(diskImage.totalBlocks)")
                        InfoRow(label: "Free Blocks",  value: "\(diskImage.freeBlocks)")
                        InfoRow(label: "Block Size",   value: "1024 bytes")
                        InfoRow(label: "Free Space",   value: formatSize(diskImage.freeBlocks * 1024))
                    }
                    InfoCard(title: "Disk Format") {
                        InfoRow(label: "Type",           value: "Akai S3000")
                        InfoRow(label: "Sector Size",    value: "1024 bytes")
                        InfoRow(label: "Sectors/Track",  value: "10")
                        InfoRow(label: "Tracks",         value: "80 × 2")
                        InfoRow(label: "Total Capacity", value: "1.64 MB")
                    }
                    InfoCard(title: "File Path") {
                        if let url = diskImage.imageURL {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                if !diskImage.samples.isEmpty {
                    InfoCard(title: "Samples") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(diskImage.samples) { s in
                                HStack {
                                    Text(s.header.name.isEmpty ? s.directoryEntry.name : s.header.name)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text("\(s.header.sampleRate)Hz")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(midiNoteName(s.header.midiRootNote))
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                                if diskImage.samples.last?.id != s.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024       { return "\(bytes) B" }
        if bytes < 1024*1024  { return String(format: "%.1f KB", Double(bytes)/1024) }
        return String(format: "%.1f MB", Double(bytes)/1024/1024)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        // -2, not -1: matches the real S3000XL's own octave display (confirmed
        // against hardware), not the common "middle C = C4" MIDI convention.
        let octave = Int(note) / 12 - 2
        return "\(names[Int(note) % 12])\(octave)"
    }
}
