import SwiftUI

// MARK: - Waveform View

struct WaveformView: View {
    let audioData: Data
    @State private var waveformPoints: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if waveformPoints.isEmpty {
                    Text("No audio data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 1)

                    WaveformShape(points: waveformPoints)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.blue.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    WaveformShape(points: waveformPoints)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .scaleEffect(x: 1, y: -1)
                }
            }
            .onAppear { computeWaveform(width: geo.size.width) }
            .onChange(of: geo.size.width) { w in computeWaveform(width: w) }
        }
    }

    private func computeWaveform(width: CGFloat) {
        guard !audioData.isEmpty else { return }
        let buckets = Int(width * 2)
        guard buckets > 0 else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let samplesPerBucket = max(1, (audioData.count / 2) / buckets)
            var points: [CGFloat] = []

            for b in 0..<buckets {
                var maxAmp: Int16 = 0
                let startSample = b * samplesPerBucket
                let endSample = min(startSample + samplesPerBucket, audioData.count / 2)
                for s in startSample..<endSample {
                    let byteIdx = s * 2
                    if byteIdx + 1 < audioData.count {
                        // S3000 audio is 16-bit signed little-endian
                        let sample = Int16(bitPattern:
                            UInt16(audioData[byteIdx]) | (UInt16(audioData[byteIdx + 1]) << 8)
                        )
                        if abs(sample) > abs(maxAmp) { maxAmp = sample }
                    }
                }
                points.append(CGFloat(abs(maxAmp)) / 32768.0)
            }

            DispatchQueue.main.async { self.waveformPoints = points }
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
