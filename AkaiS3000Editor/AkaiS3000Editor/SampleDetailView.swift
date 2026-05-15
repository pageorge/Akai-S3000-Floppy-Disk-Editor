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

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name)
                            .font(.system(.title, design: .monospaced).bold())
                        Text("Sample · \(formatSize(Int(sample.directoryEntry.length)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    // Export button
                    Button {
                        exportWAV()
                    } label: {
                        Label("Export WAV", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)

                    // Play button
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help(isPlaying ? "Stop" : "Preview")
                }

                // Waveform
                WaveformView(audioData: sample.audioData)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider()

                // Properties grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    // Sample info
                    InfoCard(title: "Sample Info") {
                        InfoRow(label: "Sample Rate", value: "\(sample.header.sampleRate) Hz")
                        InfoRow(label: "Duration", value: formatDuration())
                        InfoRow(label: "Channels", value: sample.header.numChannels == 1 ? "Mono" : "Stereo")
                        InfoRow(label: "Bit Depth", value: "\(sample.header.bitDepth)-bit")
                        InfoRow(label: "Samples", value: "\(sample.header.numSamples)")
                    }

                    // Pitch settings (editable)
                    InfoCard(title: "Pitch") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Root Note")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Picker("", selection: $editedRootNote) {
                                    ForEach(0..<128) { note in
                                        Text(midiNoteName(UInt8(note))).tag(note)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)
                                .onChange(of: editedRootNote) { _ in isDirty = true }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Fine Tune")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedFineTune))¢")
                                        .font(.system(.body, design: .monospaced))
                                }
                                Slider(value: $editedFineTune, in: -50...50, step: 1)
                                    .onChange(of: editedFineTune) { _ in isDirty = true }
                            }

                            HStack {
                                Text("Loudness")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(editedLoudness))")
                                    .font(.system(.body, design: .monospaced))
                            }
                            Slider(value: $editedLoudness, in: 0...99, step: 1)
                                .onChange(of: editedLoudness) { _ in isDirty = true }
                        }
                    }
                }

                // Loop settings
                InfoCard(title: "Loop") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Loop Enabled", isOn: $editedLoopEnabled)
                            .onChange(of: editedLoopEnabled) { _ in isDirty = true }

                        if editedLoopEnabled {
                            let maxSamples = Double(max(sample.header.numSamples, 1))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop Start")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopStart))")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopStart, in: 0...max(maxSamples - 1, 1))
                                    .onChange(of: editedLoopStart) { _ in
                                        if editedLoopStart >= editedLoopEnd { editedLoopEnd = editedLoopStart + 1 }
                                        isDirty = true
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop End")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopEnd))")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopEnd, in: 0...maxSamples)
                                    .onChange(of: editedLoopEnd) { _ in
                                        if editedLoopEnd <= editedLoopStart { editedLoopStart = max(0, editedLoopEnd - 1) }
                                        isDirty = true
                                    }
                            }
                        }
                    }
                }

                // Save changes button
                if isDirty {
                    HStack {
                        Spacer()
                        Button("Revert") {
                            revert()
                        }
                        .buttonStyle(.bordered)

                        Button("Save to Disk Image") {
                            saveChanges()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .alert(showingSaveAlert ? "Saved" : "Error", isPresented: .constant(showingSaveAlert || !saveMessage.isEmpty && saveMessage != "OK")) {
            Button("OK") { saveMessage = ""; showingSaveAlert = false }
        } message: {
            Text(saveMessage)
        }
    }

    // MARK: - Actions

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
                saveMessage = "Exported successfully to \(url.lastPathComponent)"
                showingSaveAlert = true
            } catch {
                saveMessage = error.localizedDescription
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.stop()
            isPlaying = false
            return
        }

        do {
            let wavData = try diskImage.exportSampleAsWAV(sample: sample)
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.play()
            isPlaying = true
            audioPlayer?.delegate = nil
            // Auto-stop tracking via timer
            DispatchQueue.main.asyncAfter(deadline: .now() + (audioPlayer?.duration ?? 1) + 0.1) {
                isPlaying = false
            }
        } catch {
            // silent fail — just don't play
        }
    }

    private func saveChanges() {
        // Build updated sample with new header values
        var updatedHeader = sample.header
        updatedHeader.midiRootNote = UInt8(editedRootNote)
        updatedHeader.fineTune = Int8(editedFineTune)
        updatedHeader.loopEnabled = editedLoopEnabled
        updatedHeader.loopStart = UInt32(editedLoopStart)
        updatedHeader.loopEnd = UInt32(editedLoopEnd)
        updatedHeader.loudness = UInt8(editedLoudness)

        // Patch raw header bytes
        var rawHeader = sample.header.rawHeader
        if rawHeader.count > 0x0D {
            rawHeader[0x0D] = UInt8(editedRootNote)
            rawHeader[0x0E] = UInt8(bitPattern: Int8(editedFineTune))
            rawHeader[0x0F] = UInt8(editedLoudness)
        }
        if rawHeader.count > 0x14 {
            rawHeader[0x10] = UInt8(editedLoopStart) & 0xFF
            rawHeader[0x11] = UInt8((UInt32(editedLoopStart) >> 8) & 0xFF)
            rawHeader[0x12] = UInt8(UInt32(editedLoopEnd) & 0xFF)
            rawHeader[0x13] = UInt8((UInt32(editedLoopEnd) >> 8) & 0xFF)
            rawHeader[0x14] = editedLoopEnabled ? 1 : 0
        }
        updatedHeader.rawHeader = rawHeader

        var updatedSample = sample
        updatedSample.header = updatedHeader

        do {
            try diskImage.writeSampleToImage(sample: updatedSample)
            isDirty = false
            saveMessage = "Changes saved to disk image"
            showingSaveAlert = true
        } catch {
            saveMessage = error.localizedDescription
        }
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

    // MARK: - Formatting helpers

    private func formatDuration() -> String {
        guard sample.header.sampleRate > 0 else { return "—" }
        let seconds = Double(sample.header.numSamples) / Double(sample.header.sampleRate)
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(note) / 12 - 1
        return "\(names[Int(note) % 12])\(octave)"
    }
}

// MARK: - Sample List

struct SampleListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedSampleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text("Samples")
                    .font(.title2.bold())
                Spacer()
                Text("\(diskImage.samples.count) files")
                    .foregroundStyle(.secondary)
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
                    TableColumn("Root") { s in
                        Text(midiNoteName(s.header.midiRootNote))
                    }
                    .width(50)
                    TableColumn("Rate") { s in
                        Text("\(s.header.sampleRate / 1000)kHz")
                    }
                    .width(60)
                    TableColumn("Duration") { s in
                        let dur = s.header.sampleRate > 0
                            ? Double(s.header.numSamples) / Double(s.header.sampleRate)
                            : 0
                        return Text(dur < 1 ? String(format: "%.0fms", dur*1000) : String(format: "%.2fs", dur))
                    }
                    .width(70)
                    TableColumn("Loop") { s in
                        Image(systemName: s.header.loopEnabled ? "repeat" : "minus")
                            .foregroundStyle(s.header.loopEnabled ? .blue : .secondary)
                    }
                    .width(40)
                    TableColumn("Size") { s in
                        Text(formatSize(Int(s.directoryEntry.length)))
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                }
            }
        }
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(note) / 12 - 1
        return "\(names[Int(note) % 12])\(octave)"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024*1024 { return String(format: "%.0fKB", Double(bytes)/1024) }
        return String(format: "%.1fMB", Double(bytes)/1024/1024)
    }
}
