import SwiftUI
import AVFoundation

struct SampleDetailView: View {
    let sample: AkaiSample
    @ObservedObject var diskImage: AkaiDiskImage

    @State private var editedRootNote: Int
    @State private var editedFineTune: Double
    @State private var editedSemitone: Double
    @State private var editedLoopEnabled: Bool
    @State private var editedLoopStart: Double
    @State private var editedLoopEnd: Double
    @State private var isPlaying = false
    @State private var audioEngine: AVAudioEngine?
    @State private var playerNode: AVAudioPlayerNode?
    @State private var loopStartFrame: Double = 0
    @State private var loopFrameCount: Double = 0
    @State private var totalPlayFrames: Double = 0
    @State private var playheadPosition: Double = 0
    @State private var playheadTimer: Timer?
    @State private var toast: ToastData?
    @State private var isDirty = false
    @State private var keyMonitor: Any?
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @FocusState private var nameFieldFocused: Bool

    init(sample: AkaiSample, diskImage: AkaiDiskImage) {
        self.sample = sample
        self.diskImage = diskImage
        _editedRootNote = State(initialValue: Int(sample.header.midiRootNote))
        _editedFineTune = State(initialValue: Double(sample.header.fineTune))
        _editedLoopEnabled = State(initialValue: sample.header.loopEnabled)
        // When the sample has no loop set, default the start to 0; otherwise
        // preserve the stored loop start so existing loop points aren't lost.
        _editedLoopStart = State(initialValue: sample.header.loopEnabled
            ? Double(sample.header.loopStart)
            : 0)
        // loopEnd comes straight from the header model: the real loop region
        // [loopStart, loopStart+len), clamped so it never exceeds the buffer
        // (there's no audio past numSamples).
        _editedLoopEnd = State(initialValue: Double(sample.header.loopEnd))
        _editedSemitone = State(initialValue: Double(sample.header.semitoneTune))
    }

    /// Current display name, preferring the live disk-image copy (so a rename
    /// elsewhere is reflected) and falling back to the directory entry.
    private var currentName: String {
        let live = diskImage.samples.first(where: { $0.id == sample.id })
        let name = live?.header.name ?? sample.header.name
        return name.isEmpty ? (live?.directoryEntry.name ?? sample.directoryEntry.name) : name
    }

    /// Number of audio frames — the canonical sample count from the header
    /// (slen @ 0x1A), which the Akai itself reports and which equals the stored
    /// audio length. Single source of truth for the waveform, loop sliders and
    /// playback.
    private var audioFrameCount: Int {
        Int(sample.header.numSamples)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if isEditingName {
                            HStack(spacing: 8) {
                                TextField("Sample name", text: $editedName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.title2, design: .monospaced))
                                    .frame(maxWidth: 280)
                                    .focused($nameFieldFocused)
                                    .onChange(of: editedName) { _, newValue in
                                        // Live-filter to the Akai character set, max 12 chars.
                                        let clean = AkaiDiskImage.sanitizeName(newValue)
                                        if clean != newValue { editedName = clean }
                                    }
                                    .onSubmit { commitRename() }
                                Text("\(editedName.count)/12")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Button { commitRename() } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Save name")
                                .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button { cancelRename() } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Cancel")
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(currentName)
                                    .font(.system(.title, design: .monospaced).bold())
                                    .textSelection(.enabled)
                                Button { beginRename() } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.borderless)
                                .help("Rename sample")
                            }
                        }
                        Text("Sample · \(formatSize(Int(sample.directoryEntry.size)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { saveChanges() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isDirty)
                    .help("Save changes to disk image")
                    Button { exportWAV() } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .help("Export as WAV")
                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .help(isPlaying ? "Stop (Space)" : "Play (Space)")
                }

                WaveformView(
                    audioData: sample.audioData,
                    numSamples: Int(sample.header.numSamples),
                    loopEnabled: editedLoopEnabled,
                    loopStart: $editedLoopStart,
                    loopEnd: $editedLoopEnd,
                    playhead: playheadPosition
                )
                    .id(sample.id)   // force a fresh WaveformView (and @State) per sample,
                                     // so switching samples can never leave stale waveMin/
                                     // waveMax from a previous selection.
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    InfoCard(title: "Sample Info") {
                        InfoRow(label: "Sample Rate", value: "\(sample.header.sampleRate) Hz")
                        InfoRow(label: "Duration", value: formatDuration())
                        InfoRow(label: "Channels", value: "Mono")
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
                                .onChange(of: editedRootNote) { _, _ in commitEditsToImage() }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Fine Tune").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedFineTune))¢").font(.system(.body, design: .monospaced))
                                }
                                Slider(value: $editedFineTune, in: -50...50, step: 1)
                                    .onChange(of: editedFineTune) { _, _ in commitEditsToImage() }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Semitone Tune").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedSemitone) > 0 ? "+" : "")\(Int(editedSemitone))")
                                        .font(.system(.body, design: .monospaced))
                                }
                                Slider(value: $editedSemitone, in: -36...36, step: 1)
                                    .onChange(of: editedSemitone) { _, _ in commitEditsToImage() }
                            }
                        }
                    }
                }

                InfoCard(title: "Loop") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Loop Enabled", isOn: $editedLoopEnabled)
                            .onChange(of: editedLoopEnabled) { _, _ in commitEditsToImage() }
                        if editedLoopEnabled {
                            let maxSamples = Double(max(audioFrameCount, 1))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop Start").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopStart))").font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopStart, in: 0...max(maxSamples - 1, 1))
                                    .onChange(of: editedLoopStart) { _, _ in
                                        if editedLoopStart >= editedLoopEnd { editedLoopEnd = editedLoopStart + 1 }
                                        commitEditsToImage()
                                    }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Loop End").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(editedLoopEnd))").font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $editedLoopEnd, in: 0...maxSamples)
                                    .onChange(of: editedLoopEnd) { _, _ in
                                        if editedLoopEnd <= editedLoopStart { editedLoopStart = max(0, editedLoopEnd - 1) }
                                        commitEditsToImage()
                                    }
                            }
                        }
                    }
                }

                if isDirty {
                    HStack {
                        Spacer()
                        Button("Reset") { resetSampleEdits() }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 49 && !self.isEditingName { self.togglePlayback(); return nil }
                return event
            }
        }
        .onChange(of: isDirty) { _, _ in diskImage.hasUnsavedChanges = isDirty }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            diskImage.isEditingText = false
            stopPlayback()
        }
        .toast($toast)
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
                toast = ToastData(message: "Exported to \(url.lastPathComponent)")
            } catch { toast = ToastData(message: error.localizedDescription, isError: true) }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        startPlayback()
    }

    private func stopPlayback() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        isPlaying = false
        playheadTimer?.invalidate()
        playheadTimer = nil
        playheadPosition = 0
    }

    /// Build a float buffer from the sample's 16-bit mono PCM and play it through
    /// an AVAudioEngine. All S3000 samples are mono (stereo is stored as a -L/-R
    /// pair of mono samples). If looping is enabled, the intro (0 → loopEnd) plays
    /// once, then the loop region (loopStart → loopEnd) repeats until stopped.
    private func startPlayback() {
        let pcm = sample.audioData
        guard !pcm.isEmpty else { return }
        // Sample rate comes straight from the header (srate @ 0x8A). No fallback:
        // a valid S3000 sample always carries its rate.
        let baseRate = Double(sample.header.sampleRate)
        guard baseRate > 0 else { return }

        // Apply semitone + fine (cents) tune as a playback-rate multiplier so the
        // preview is pitched the way the Akai would play it. 12 semitones = 2x.
        // Root note is intentionally NOT applied: it's only meaningful relative to
        // a pressed MIDI key, which doesn't exist when auditioning the raw sample.
        let semis = editedSemitone + editedFineTune / 100.0
        let pitchRatio = pow(2.0, semis / 12.0)
        let sr = baseRate * pitchRatio

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sr,
                                         channels: 1,
                                         interleaved: false) else { return }

        // 16-bit LE PCM → float, single channel.
        let frameCount = pcm.count / 2
        guard frameCount > 0 else { return }

        func makeBuffer(fromFrame start: Int, toFrame end: Int) -> AVAudioPCMBuffer? {
            // Clamp defensively: a loop end can legitimately exceed the stored
            // audio length on hardware samples, and start must never exceed end.
            let s = max(0, min(start, frameCount))
            let e = max(s + 1, min(end, frameCount))
            let count = e - s
            guard count > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(count)) else { return nil }
            buf.frameLength = AVAudioFrameCount(count)
            guard let channelData = buf.floatChannelData else { return nil }
            pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let i16 = raw.bindMemory(to: Int16.self)
                for frame in 0..<count {
                    let srcIdx = s + frame
                    channelData[0][frame] = srcIdx < i16.count ? Float(i16[srcIdx]) / 32768.0 : 0
                }
            }
            return buf
        }

        // Build the loop preview as a simple bounded loop: the run-in
        // (0 → loopStart) once, then loopStart → loopEnd repeated. loopEnd is the
        // real header-derived end (at+len, clamped to the buffer) — NOT always
        // the buffer end. Verified against hardware: at=48,len=48 loops just
        // samples 48→96, not 48→end-of-buffer.
        func makeBoundedLoop(introStart: Int, loopStart: Int, loopEnd: Int,
                             targetSeconds: Double) -> AVAudioPCMBuffer? {
            guard loopEnd > 0 else { return nil }
            let i0 = max(0, min(introStart, loopEnd))
            let ls = max(0, min(loopStart, loopEnd - 1))
            let le = max(ls + 1, min(loopEnd, frameCount))
            let loopLen = le - ls
            guard loopLen > 0 else { return nil }
            let introLen = max(0, ls - i0)
            let passes = max(1, Int((sr * targetSeconds) / Double(loopLen)))
            let total = introLen + loopLen * passes
            guard total > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(total)) else { return nil }
            buf.frameLength = AVAudioFrameCount(total)
            guard let out = buf.floatChannelData else { return nil }

            pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let i16 = raw.bindMemory(to: Int16.self)
                func sampleAt(_ idx: Int) -> Float {
                    idx >= 0 && idx < i16.count ? Float(i16[idx]) / 32768.0 : 0
                }
                var w = 0
                for f in 0..<introLen { out[0][w] = sampleAt(i0 + f); w += 1 }
                for _ in 0..<passes {
                    for f in 0..<loopLen { out[0][w] = sampleAt(ls + f); w += 1 }
                }
            }
            return buf
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let useLoop = editedLoopEnabled
        // loopStart/loopEnd come straight from the sliders, which mirror the real
        // header fields (at, and at+len clamped to the buffer) — the loop region
        // is genuinely [loopStart, loopEnd), not always the whole buffer.
        let bufferLen = frameCount
        let loopAtFr = max(0, min(Int(editedLoopStart), bufferLen - 1))
        let loopEndFr = max(loopAtFr + 1, min(Int(editedLoopEnd), bufferLen))

        // Bookkeeping for the playhead overlay.
        loopStartFrame = Double(loopAtFr)
        loopFrameCount = Double(useLoop ? loopEndFr - loopAtFr : 0)
        totalPlayFrames = Double(frameCount)

        do {
            try engine.start()
        } catch {
            toast = ToastData(message: "Playback failed: \(error.localizedDescription)", isError: true)
            return
        }

        if useLoop {
            // Bounded loop: run-in once, then loopStart → loopEnd repeated.
            if let preview = makeBoundedLoop(introStart: 0,
                                             loopStart: loopAtFr,
                                             loopEnd: loopEndFr,
                                             targetSeconds: 3.0) {
                node.scheduleBuffer(preview, at: nil, options: [.loops])
            }
        } else {
            if let whole = makeBuffer(fromFrame: 0, toFrame: frameCount) {
                node.scheduleBuffer(whole, at: nil, options: []) {
                    // Auto-stop at end when not looping.
                    DispatchQueue.main.async { self.stopPlayback() }
                }
            }
        }

        audioEngine = engine
        playerNode = node
        node.play()
        isPlaying = true
        playheadPosition = 0

        // Drive the playhead from the node's render time.
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
            guard let node = self.playerNode,
                  let lastRender = node.lastRenderTime,
                  let playerTime = node.playerTime(forNodeTime: lastRender) else { return }
            let played = Double(playerTime.sampleTime)
            let total = self.totalPlayFrames
            guard total > 0 else { return }

            if self.editedLoopEnabled && self.loopFrameCount > 0 {
                // First pass plays 0 → loopEnd; afterwards the playhead wraps
                // within the loopStart → loopEnd region.
                let firstPassFrames = self.loopStartFrame + self.loopFrameCount  // 0 → loopEnd
                if played < firstPassFrames {
                    self.playheadPosition = played / total
                } else {
                    let into = (played - firstPassFrames).truncatingRemainder(dividingBy: self.loopFrameCount)
                    self.playheadPosition = (self.loopStartFrame + into) / total
                }
            } else {
                self.playheadPosition = min(played / total, 1.0)
            }
        }
    }

    private func saveChanges() {
        var updatedHeader = sample.header
        updatedHeader.midiRootNote = UInt8(editedRootNote)
        updatedHeader.fineTune = Int8(editedFineTune)
        updatedHeader.loopEnabled = editedLoopEnabled
        updatedHeader.loopStart = UInt32(editedLoopStart)
        updatedHeader.loopEnd = UInt32(editedLoopEnd)
        var updatedSample = sample
        updatedSample.header = updatedHeader
        do {
            try diskImage.writeSampleToImage(sample: updatedSample)
            isDirty = false
            toast = ToastData(message: "Changes saved")
        } catch { toast = ToastData(message: error.localizedDescription, isError: true) }
    }

    /// Build a sample carrying the current edits.
    private func editedSample() -> AkaiSample {
        var h = sample.header
        h.midiRootNote = UInt8(editedRootNote)
        h.fineTune = Int8(editedFineTune)
        h.loopEnabled = editedLoopEnabled
        h.loopStart = UInt32(editedLoopStart)
        h.loopEnd = UInt32(editedLoopEnd)
        var s = sample
        s.header = h
        return s
    }

    /// Push current edits into the in-memory image so a global Save All persists
    /// them even if the per-sample Save button wasn't used. Does not write a file.
    private func commitEditsToImage() {
        isDirty = true
        diskImage.applySampleEdits(editedSample())
    }

    private func beginRename() {
        editedName = currentName
        isEditingName = true
        diskImage.isEditingText = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func cancelRename() {
        isEditingName = false
        nameFieldFocused = false
        diskImage.isEditingText = false
    }

    private func commitRename() {
        let clean = AkaiDiskImage.sanitizeName(editedName)
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // No-op if unchanged.
        if clean == currentName {
            isEditingName = false
            nameFieldFocused = false
            diskImage.isEditingText = false
            return
        }
        do {
            try diskImage.renameSample(id: sample.id, to: clean)
            isEditingName = false
            nameFieldFocused = false
            diskImage.isEditingText = false
            toast = ToastData(message: "Renamed to \(clean)")
        } catch {
            toast = ToastData(message: error.localizedDescription, isError: true)
        }
    }

    /// Reset tuning (fine + semitone) and the loop to defaults: tune to 0, loop
    /// disabled, loop start at 0 and loop end at the end of the sample. Root note
    /// is left as-is.
    private func resetSampleEdits() {
        editedFineTune = 0
        editedSemitone = 0
        editedLoopEnabled = false
        editedLoopStart = 0
        editedLoopEnd = Double(max(audioFrameCount - 1, 0))
        commitEditsToImage()
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
