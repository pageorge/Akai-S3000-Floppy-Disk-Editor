import SwiftUI

// MARK: - Waveform View

struct WaveformView: View {
    let audioData: Data
    let numSamples: Int
    let loopEnabled: Bool
    let loopStart: Binding<Double>?
    let loopEnd: Binding<Double>?
    @State private var waveformPoints: [CGFloat] = []

    init(audioData: Data, numSamples: Int = 0, loopEnabled: Bool = false,
         loopStart: Binding<Double>? = nil, loopEnd: Binding<Double>? = nil) {
        self.audioData = audioData
        self.numSamples = numSamples
        self.loopEnabled = loopEnabled
        self.loopStart = loopStart
        self.loopEnd = loopEnd
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .top, endPoint: .bottom
                )

                if waveformPoints.isEmpty {
                    Text("No audio data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)

                    WaveformShape(points: waveformPoints)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.4)],
                            startPoint: .top, endPoint: .bottom))

                    WaveformShape(points: waveformPoints)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.1)],
                            startPoint: .top, endPoint: .bottom))
                        .scaleEffect(x: 1, y: -1)

                    // Loop region overlay
                    if loopEnabled, numSamples > 0,
                       let startBinding = loopStart, let endBinding = loopEnd {
                        let startFrac = CGFloat(startBinding.wrappedValue) / CGFloat(numSamples)
                        let endFrac   = CGFloat(endBinding.wrappedValue)   / CGFloat(numSamples)
                        let startX    = startFrac * geo.size.width
                        let endX      = endFrac   * geo.size.width

                        // Shaded loop region
                        Rectangle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: max(0, endX - startX))
                            .offset(x: startX - geo.size.width / 2 + (endX - startX) / 2)

                        // Loop start handle
                        LoopHandle(color: .green, label: "S")
                            .offset(x: startX - geo.size.width / 2)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    let newVal = frac * Double(numSamples)
                                    if newVal < endBinding.wrappedValue {
                                        startBinding.wrappedValue = newVal
                                    }
                                }
                            )

                        // Loop end handle
                        LoopHandle(color: .red, label: "E")
                            .offset(x: endX - geo.size.width / 2)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let frac = max(0, min(1, value.location.x / geo.size.width))
                                    let newVal = frac * Double(numSamples)
                                    if newVal > startBinding.wrappedValue {
                                        endBinding.wrappedValue = newVal
                                    }
                                }
                            )
                    }
                }
            }
            .onAppear { computeWaveform(width: geo.size.width) }
            .onChange(of: geo.size.width) { computeWaveform(width: geo.size.width) }
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

    var body: some View {
        VStack(spacing: 0) {
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
