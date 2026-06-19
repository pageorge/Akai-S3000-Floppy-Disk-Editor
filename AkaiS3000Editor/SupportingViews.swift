import SwiftUI

// MARK: - Waveform View

struct WaveformView: View {
    let audioData: Data
    let numSamples: Int
    let numChannels: Int
    let loopEnabled: Bool
    let loopStart: Binding<Double>?
    let loopEnd: Binding<Double>?
    let playhead: Double
    @State private var waveformPoints: [CGFloat] = []

    init(audioData: Data, numSamples: Int = 0, numChannels: Int = 1, loopEnabled: Bool = false,
         loopStart: Binding<Double>? = nil, loopEnd: Binding<Double>? = nil,
         playhead: Double = 0) {
        self.audioData = audioData
        self.numSamples = numSamples
        self.numChannels = max(1, numChannels)
        self.loopEnabled = loopEnabled
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.playhead = playhead
    }

    /// The true number of audio frames present in `audioData` (per channel).
    /// This is the ground truth for both the waveform x-axis and loop-region
    /// scaling — the header's numSamples can disagree, which would otherwise
    /// make the drawn loop region diverge from what actually plays.
    private var frameCount: Int {
        let bytesPerFrame = numChannels * 2
        let fromAudio = bytesPerFrame > 0 ? audioData.count / bytesPerFrame : 0
        return fromAudio > 0 ? fromAudio : max(numSamples, 1)
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

                    WaveformShape(points: waveformPoints)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.4)],
                            startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)

                    WaveformShape(points: waveformPoints)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.1)],
                            startPoint: .top, endPoint: .bottom))
                        .scaleEffect(x: 1, y: -1)
                        .allowsHitTesting(false)

                    if loopEnabled, frameCount > 0,
                       let startBinding = loopStart, let endBinding = loopEnd {
                        let startFrac = CGFloat(startBinding.wrappedValue) / CGFloat(frameCount)
                        let endFrac   = CGFloat(endBinding.wrappedValue)   / CGFloat(frameCount)
                        let startX    = startFrac * geo.size.width
                        let endX      = endFrac   * geo.size.width
                        let regionW   = max(0, endX - startX)

                        Rectangle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: regionW, height: geo.size.height)
                            .offset(x: startX)
                            .allowsHitTesting(false)

                        // Loop start handle — bar on its leading edge, sat at startX
                        LoopHandle(color: .green, label: "S", barEdge: .leading)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: startX)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    let newVal = frac * Double(frameCount)
                                    if newVal < endBinding.wrappedValue - 100 {
                                        startBinding.wrappedValue = newVal
                                    }
                                }
                            )

                        // Loop end handle — bar on its trailing edge, sat at endX
                        LoopHandle(color: .red, label: "E", barEdge: .trailing)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: endX - 14)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    let newVal = frac * Double(frameCount)
                                    if newVal > startBinding.wrappedValue + 100 {
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
        }
    }

    private func computeWaveform(width: CGFloat) {
        guard !audioData.isEmpty else { return }
        let buckets = Int(width * 2)
        guard buckets > 0 else { return }
        let localData = audioData

        DispatchQueue.global(qos: .userInitiated).async {
            let samplesPerBucket = max(1, (localData.count / 2) / buckets)
            var points: [CGFloat] = []

            for b in 0..<buckets {
                var maxAmp: Int32 = 0
                let startSample = b * samplesPerBucket
                let endSample = min(startSample + samplesPerBucket, localData.count / 2)
                for s in startSample..<endSample {
                    let byteIdx = s * 2
                    if byteIdx + 1 < localData.count {
                        let sample = Int32(Int16(bitPattern:
                            UInt16(localData[byteIdx]) | (UInt16(localData[byteIdx + 1]) << 8)
                        ))
                        if abs(sample) > maxAmp { maxAmp = abs(sample) }
                    }
                }
                points.append(CGFloat(maxAmp) / 32768.0)
            }

            DispatchQueue.main.async { self.waveformPoints = points }
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

struct WaveformShape: Shape {
    let points: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard !points.isEmpty else { return Path() }
        var path = Path()
        let width  = rect.width
        let height = rect.height
        let midY   = height / 2
        let step   = width / CGFloat(points.count)

        path.move(to: CGPoint(x: 0, y: midY))
        for (i, point) in points.enumerated() {
            let x = CGFloat(i) * step
            let y = midY - (point * midY)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: midY))
        path.closeSubpath()
        return path
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
