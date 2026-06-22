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
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)

            // Click the path to reveal in Finder.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
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
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy path")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            content().padding(.top, 4)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
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

// MARK: - Disk Info View

struct DiskInfoView: View {
    @ObservedObject var diskImage: AkaiDiskImage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(diskImage.diskName.isEmpty ? "Untitled Disk" : diskImage.diskName)
                            .font(.title.bold())
                        Text("Akai S3000 Disk Image")
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    InfoCard(title: "Contents") {
                        InfoRow(label: "Samples",     value: "\(diskImage.samples.count)")
                        InfoRow(label: "Programs",    value: "\(diskImage.programs.count)")
                        InfoRow(label: "Total Files", value: "\(diskImage.samples.count + diskImage.programs.count)")
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
        let octave = Int(note) / 12 - 1
        return "\(names[Int(note) % 12])\(octave)"
    }
}
