import SwiftUI
import AVFoundation

struct SampleDetailView: View {
    let sample: AkaiSample
    @ObservedObject var diskImage: AkaiDiskImage

    @State private var editedRootNote: Int
    @State private var editedFineTune: Double
    @State private var editedLoopEnabled: Bool
    @State private var editedLoopStart: Double
    @State private var editedLoopEnd: Double
    @State private var editedLoudness: Double
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showingSaveAlert = false
    @State private var saveMessage = ""
    @State private var isDirty = false
    @State private var keyMonitor: Any?

    init(sample: AkaiSample, diskImage: AkaiDiskImage) {
        self.sample = sample
        self.diskImage = diskImage
        _editedRootNote = State(initialValue: Int(sample.header.midiRootNote))
        _editedFineTune = State(initialValue: Double(sample.header.fineTune))
        _editedLoopEnabled = State(initialValue: sample.header.loopEnabled)
        _editedLoopStart = State(initialValue: Double(sample.header.loopStart))
        _editedLoopEnd = State(initialValue: Double(sample.header.loopEnd))
        _editedLoudness = State(initialValue: Double(sample.header.loudness))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name)
                            .font(.system(.title, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Text("Sample · \(formatSize(Int(sample.directoryEntry.size)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { exportWAV() } label: {
                        Label("Export WAV", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.borderedProminent)
                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help(isPlaying ? "Stop (Space)" : "Preview (Space)")
                }

                WaveformView(
                    audioData: sample.audioData,
                    numSamples: Int(sample.header.numSamples),
                    loopEnabled: editedLoopEnabled,
                    loopStart: $editedLoopStart,
                    loopEnd: $editedLoopEnd
                )
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    InfoCard(title: "Sample Info") {
                        InfoRow(label: "Sample Rate", value: "\(sample.header.sampleRate) Hz")
                        InfoRow(label: "Duration", value: formatDuration())
                        InfoRow(label: "Channels", value: sample.header.numChannels == 1 ? "Mono" : "Stereo")
                        InfoRow(label: "Bit Depth", value: "\(sample.header.bitDepth)-bit")
                        InfoRow(label: "Samples", value: "\(sample.header.numSamples)")
                    }
                    InfoCard(title: "Pitch") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Root Note").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Picker("", selection: $editedRootNote) {
                                    ForEach(0..<128) { note in Text(midiNoteName(UInt8(note))).tag(note) }
                                }
                                .labelsHidden().frame(width: 80)
                                .onChange(of: editedRootNote) { isDirty = true }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Fine Tune").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedFineTune))¢").font(.system(.body, design: .monospaced))
                                }
                                Slider(value: $editedFineTune, in: -50...50, step: 1)
                                    .onChange(of: editedFineTune) { isDirty = true }
                            }
                            HStack {
                                Text("Loudness").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(editedLoudness))").font(.system(.body, design: .monospaced))
                            }
                            Slider(value: $editedLoudness, in: 0...99, step: 1)
                                .onChange(of: editedLoudness) { isDirty = true }
                        }
                    }
                }

                InfoCard(title: "Loop") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Loop", isOn: $editedLoopEnabled)
                            .onChange(of: editedLoopEnabled) { isDirty = true }
                        if editedLoopEnabled {
                            let maxSamples = Double(max(sample.header.numSamples, 1))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop Start").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopStart))").font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopStart, in: 0...max(maxSamples - 1, 1))
                                    .onChange(of: editedLoopStart) {
                                        if editedLoopStart >= editedLoopEnd { editedLoopEnd = editedLoopStart + 1 }
                                        isDirty = true
                                    }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop End").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopEnd))").font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopEnd, in: 0...maxSamples)
                                    .onChange(of: editedLoopEnd) {
                                        if editedLoopEnd <= editedLoopStart { editedLoopStart = max(0, editedLoopEnd - 1) }
                                        isDirty = true
                                    }
                            }
                        }
                    }
                }

                if isDirty {
                    HStack {
                        Spacer()
                        Button("Revert") { revert() }.buttonStyle(.bordered)
                        Button("Save to Disk Image") { saveChanges() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 49 { self.togglePlayback(); return nil }
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            audioPlayer?.stop()
        }
        .alert(showingSaveAlert ? "Saved" : "Error",
               isPresented: .constant(showingSaveAlert || (!saveMessage.isEmpty && saveMessage != "OK"))) {
            Button("OK") { saveMessage = ""; showingSaveAlert = false }
        } message: {
            Text(saveMessage)
        }
    }

    private func exportWAV() {
        let panel = NSSavePanel()
        let safeName = (sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name)
            .trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = "\(safeName).wav"
        panel.allowedContentTypes = [.audio]
        panel.title = "Export Sample as WAV"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let wavData = try diskImage.exportSampleAsWAV(sample: sample)
                try wavData.write(to: url)
                saveMessage = "Exported to \(url.lastPathComponent)"
                showingSaveAlert = true
            } catch { saveMessage = error.localizedDescription }
        }
    }

    private func togglePlayback() {
        if isPlaying { audioPlayer?.stop(); isPlaying = false; return }
        do {
            let wavData = try diskImage.exportSampleAsWAV(sample: sample)
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = editedLoopEnabled ? -1 : 0  // -1 = loop forever
            audioPlayer?.play()
            isPlaying = true
            // Only auto-stop when not looping
            if !editedLoopEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + (audioPlayer?.duration ?? 1) + 0.1) {
                    self.isPlaying = false
                }
            }
        } catch {}
    }

    private func saveChanges() {
        var updatedHeader = sample.header
        updatedHeader.midiRootNote = UInt8(editedRootNote)
        updatedHeader.fineTune = Int8(editedFineTune)
        updatedHeader.loopEnabled = editedLoopEnabled
        updatedHeader.loopStart = UInt32(editedLoopStart)
        updatedHeader.loopEnd = UInt32(editedLoopEnd)
        updatedHeader.loudness = UInt8(editedLoudness)
        var updatedSample = sample
        updatedSample.header = updatedHeader
        do {
            try diskImage.writeSampleToImage(sample: updatedSample)
            isDirty = false
            saveMessage = "Changes saved"
            showingSaveAlert = true
        } catch { saveMessage = error.localizedDescription }
    }

    private func revert() {
        editedRootNote = Int(sample.header.midiRootNote)
        editedFineTune = Double(sample.header.fineTune)
        editedLoopEnabled = sample.header.loopEnabled
        editedLoopStart = Double(sample.header.loopStart)
        editedLoopEnd = Double(sample.header.loopEnd)
        editedLoudness = Double(sample.header.loudness)
        isDirty = false
    }

    private func formatDuration() -> String {
        guard sample.header.sampleRate > 0 else { return "—" }
        let s = Double(sample.header.numSamples) / Double(sample.header.sampleRate)
        return s < 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.2f s", s)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}

// MARK: - Sample List

struct SampleListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedSampleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Samples").font(.title2.bold())
                Spacer()
                Text("\(diskImage.samples.count) files").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if diskImage.samples.isEmpty {
                ContentUnavailableView("No Samples", systemImage: "waveform",
                    description: Text("This disk image contains no sample files."))
            } else {
                Table(diskImage.samples, selection: $selectedSampleID) {
                    TableColumn("Name") { s in
                        Text(s.header.name.isEmpty ? s.directoryEntry.name : s.header.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Root") { s in Text(midiNoteName(s.header.midiRootNote)) }.width(50)
                    TableColumn("Rate") { s in Text("\(s.header.sampleRate / 1000)kHz") }.width(60)
                    TableColumn("Duration") { s in
                        let dur = s.header.sampleRate > 0
                            ? Double(s.header.numSamples) / Double(s.header.sampleRate) : 0
                        return Text(dur < 1 ? String(format: "%.0fms", dur*1000) : String(format: "%.2fs", dur))
                    }.width(70)
                    TableColumn("Loop") { s in
                        Image(systemName: s.header.loopEnabled ? "repeat" : "minus")
                            .foregroundStyle(s.header.loopEnabled ? .blue : .secondary)
                    }.width(40)
                    TableColumn("Size") { s in
                        Text(formatSize(Int(s.directoryEntry.size))).foregroundStyle(.secondary)
                    }.width(70)
                }
            }
        }
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024*1024 { return String(format: "%.0fKB", Double(bytes)/1024) }
        return String(format: "%.1fMB", Double(bytes)/1024/1024)
    }
}
