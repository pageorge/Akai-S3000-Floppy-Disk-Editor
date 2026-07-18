import SwiftUI

struct ProgramDetailView: View {
    let programFile: AkaiProgramFile
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var editedProgram: AkaiProgram
    @State private var selectedKeyzoneIndices: Set<Int> = []
    @State private var anchorKeyzoneIndex: Int? = nil
    @State private var isDirty = false
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var toast: ToastData?
    @State private var showDeleteKeyzoneConfirm = false
    @State private var keyzoneKeyMonitor: Any? = nil
    @FocusState private var keyzoneListFocused: Bool
    @FocusState private var nameFieldFocused: Bool
    init(programFile: AkaiProgramFile, diskImage: AkaiDiskImage) {
        self.programFile = programFile
        self.diskImage = diskImage
        _editedProgram = State(initialValue: programFile.program)
    }

    private var currentName: String {
        let live = diskImage.programs.first(where: { $0.id == programFile.id })
        let name = live?.program.name ?? editedProgram.name
        return name.isEmpty ? (live?.directoryEntry.name ?? programFile.directoryEntry.name) : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Program name", text: $editedName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.title2, design: .monospaced))
                                .frame(maxWidth: 280)
                                .focused($nameFieldFocused)
                                .onChange(of: editedName) { _, newValue in
                                    let clean = AkaiDiskImage.sanitizeName(newValue)
                                    if clean != newValue { editedName = clean }
                                }
                                .onSubmit { commitRename() }
                            Text("\(editedName.count)/12")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Button { commitRename() } label: { Image(systemName: "checkmark.circle.fill") }
                                .buttonStyle(.borderless).help("Save name")
                                .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button { cancelRename() } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("Cancel")
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(currentName)
                                .font(.system(.title, design: .monospaced).bold())
                                .textSelection(.enabled)
                            Button { beginRename() } label: {
                                Image(systemName: "pencil").font(.system(size: 14))
                            }
                            .buttonStyle(.borderless).help("Rename program")
                        }
                    }
                    Text("Program · \(editedProgram.keyzones.count) keyzones")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Divider()
            HSplitView {
                // Left: program settings + keyzone list
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                    InfoCard(title: "Program Settings") {
                        VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("MIDI Channel").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.midiChannel) {
                                Text("All").tag(UInt8(0))
                                ForEach(1..<17) { ch in Text("\(ch)").tag(UInt8(ch)) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.midiChannel) { _, _ in commitProgramEdits() }
                        }
                        .help(editedProgram.midiChannel == 0
                            ? "Program responds to MIDI on all channels simultaneously."
                            : "Program responds only to MIDI channel \(editedProgram.midiChannel).")
                        HStack {
                            Text("Polyphony").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Stepper("\(editedProgram.polyphony)", value: $editedProgram.polyphony, in: 1...32)
                                .onChange(of: editedProgram.polyphony) { _, _ in commitProgramEdits() }
                        }
                        .help("Maximum simultaneous voices (1–32). For stereo programs this must be at least 2 — one voice per zone. Default: 32.")
                        HStack {
                            Text("Priority").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.priority) {
                                ForEach(AkaiProgramPriority.allCases) { p in Text(p.displayName).tag(p) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.priority) { _, _ in commitProgramEdits() }
                        }
                        .help("Voice priority when the sampler is pushed to its polyphony limit. LOW = stolen first; HIGH = stolen last; HOLD = notes only stolen by the same program.")
                        HStack {
                            Text("Reassignment").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.reassignment) {
                                ForEach(AkaiProgramReassignment.allCases) { r in Text(r.displayName).tag(r) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.reassignment) { _, _ in commitProgramEdits() }
                        }
                        .help("Which voice is stolen when all voices are in use. OLDEST = the longest-playing note; QUIETEST = the quietest note.")
                        HStack {
                            Text("Bend Range").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Stepper("\(editedProgram.bendRange) semitones", value: $editedProgram.bendRange, in: 0...24)
                                .onChange(of: editedProgram.bendRange) { _, _ in commitProgramEdits() }
                        }
                        .help("Pitchbend wheel/lever range, 0–24 semitones. Default is 2.")
                        HStack {
                            Text("loudness").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(editedProgram.stereoLevel) },
                                               set: { editedProgram.stereoLevel = UInt8($0); commitProgramEdits() }), in: 0...99, step: 1)
                            Text("\(editedProgram.stereoLevel)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        .help("Sets the overall loudness for the program. Affects main L/R outputs, individual outputs and effects send. 0 = silent.")
                        HStack {
                            Text("vel > loud").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(editedProgram.basicLoudness) },
                                               set: { editedProgram.basicLoudness = UInt8($0); commitProgramEdits() }), in: 0...99, step: 1)
                            Text("\(editedProgram.basicLoudness)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        .help("Velocity sensitivity. At loudness=99 this has no effect — maximum level, no velocity response.")
                        Text("Filter modulation inputs").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        HStack {
                            Text("Mod 1").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.filterModSource1) {
                                ForEach(AkaiFilterModSource.allCases) { src in Text(src.displayName).tag(src) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.filterModSource1) { _, _ in commitProgramEdits() }
                        }
                        .help(editedProgram.filterModSource1.helpText)
                        HStack {
                            Text("Mod 2").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.filterModSource2) {
                                ForEach(AkaiFilterModSource.allCases) { src in Text(src.displayName).tag(src) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.filterModSource2) { _, _ in commitProgramEdits() }
                        }
                        .help(editedProgram.filterModSource2.helpText)
                        HStack {
                            Text("Mod 3").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $editedProgram.filterModSource3) {
                                ForEach(AkaiFilterModSource.allCases) { src in Text(src.displayName).tag(src) }
                            }
                            .labelsHidden()
                            .onChange(of: editedProgram.filterModSource3) { _, _ in commitProgramEdits() }
                        }
                        .help(editedProgram.filterModSource3.helpText)
                        HStack {
                            Button {
                                editedProgram.midiChannel = 0
                                editedProgram.polyphony = 32
                                editedProgram.priority = .norm
                                editedProgram.reassignment = .oldest
                                editedProgram.bendRange = 2
                                editedProgram.stereoLevel = 99
                                editedProgram.basicLoudness = 99
                                editedProgram.filterModSource1 = .velocity
                                editedProgram.filterModSource2 = .lfo2
                                editedProgram.filterModSource3 = .env2
                                commitProgramEdits()
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                            }
                            .buttonStyle(.bordered).controlSize(.small).tint(.blue)
                            .help("Reset all program settings to hardware defaults")
                            Spacer()
                        }
                        } // end VStack inside Program Settings InfoCard
                    } // end InfoCard Program Settings
                    } // VStack
                    .padding(16)
                    } // ScrollView
                    .fixedSize(horizontal: false, vertical: true)

                    InfoCard(title: "Keyzones") {
                        VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            if selectedKeyzoneIndices.count > 1 {
                                Text("\(selectedKeyzoneIndices.count) selected")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            RoundIconButton(systemImage: "plus") { addKeyzone() }
                            RoundIconButton(systemImage: "minus", isDisabled: selectedKeyzoneIndices.isEmpty) {
                                showDeleteKeyzoneConfirm = true
                            }
                        }
                        .padding(.bottom, 4)
                    List {
                        ForEach(Array(editedProgram.keyzones.enumerated()), id: \.offset) { idx, kz in
                            KeyzoneRow(keyzone: kz, sampleNames: diskImage.samples.map { $0.header.name })
                                .listRowBackground(selectedKeyzoneIndices.contains(idx) ? Color.accentColor.opacity(0.15) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    keyzoneListFocused = true
                                    let flags = NSEvent.modifierFlags
                                    handleKeyzoneTap(idx, shift: flags.contains(.shift), command: flags.contains(.command))
                                }
                                .contextMenu {
                                    Button { addKeyzone() } label: {
                                        Label("New Keyzone", systemImage: "plus.square.on.square")
                                    }
                                    Button { cloneKeyzone(at: idx) } label: {
                                        Label("Clone", systemImage: "plus.square.on.square")
                                    }
                                    Divider()
                                    Button(role: .destructive) { showDeleteKeyzoneConfirm = true } label: {
                                        Label(selectedKeyzoneIndices.count > 1 ? "Delete \(selectedKeyzoneIndices.count) Keyzones" : "Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove { source, destination in
                            editedProgram.keyzones.move(fromOffsets: source, toOffset: destination)
                            if let idx = anchorKeyzoneIndex, source.contains(idx) {
                                let newIdx = destination > idx ? destination - 1 : destination
                                selectedKeyzoneIndices = [newIdx]
                                anchorKeyzoneIndex = newIdx
                            } else {
                                selectedKeyzoneIndices = []
                                anchorKeyzoneIndex = nil
                            }
                            commitProgramEdits()
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: .infinity)
                    .focused($keyzoneListFocused)
                    .onAppear {
                        keyzoneKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            guard !diskImage.isEditingText else { return event }
                            let hasKeyzoneContext = self.keyzoneListFocused || !self.selectedKeyzoneIndices.isEmpty
                            guard hasKeyzoneContext else { return event }
                            if event.keyCode == 53 {
                                if !self.selectedKeyzoneIndices.isEmpty {
                                    self.selectedKeyzoneIndices = []
                                    self.anchorKeyzoneIndex = nil
                                    return nil
                                }
                            }
                            if event.keyCode == 126 { moveKeyzoneSelection(by: -1); return nil }
                            if event.keyCode == 125 { moveKeyzoneSelection(by: 1);  return nil }
                            if event.keyCode == 51 || event.keyCode == 117 {
                                if !selectedKeyzoneIndices.isEmpty { showDeleteKeyzoneConfirm = true; return nil }
                            }
                            return event
                        }
                    }
                    .onDisappear {
                        if let m = keyzoneKeyMonitor { NSEvent.removeMonitor(m); keyzoneKeyMonitor = nil }
                    }
                        } // VStack inside InfoCard
                    } // InfoCard Keyzones
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .frame(maxHeight: .infinity)
                } // VStack left panel
                .frame(minWidth: 280, maxWidth: 360)

                // Right: sample picker + piano keyboard + keyzone editor
                VStack(alignment: .leading, spacing: 0) {
                    if anchorKeyzoneIndex != nil && !diskImage.samples.isEmpty {
                        GroupBox("Sample (Zone 1, Left)") {
                            FlowLayout(spacing: 6) {
                                ForEach(diskImage.samples) { sample in samplePill(for: sample) }
                            }
                        }
                        .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

                        GroupBox("Stereo Right Channel (Zone 2, optional)") {
                            VStack(alignment: .leading, spacing: 6) {
                                FlowLayout(spacing: 6) {
                                    ForEach(diskImage.samples) { sample in rightSamplePill(for: sample) }
                                }
                                Text("Pairs a second sample as the stereo right channel of this same keygroup — the real S3000 convention for stereo playback (one keygroup, two zones panned hard left/right), not two separate keygroups.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal).padding(.bottom, 4)
                    }

                    if !editedProgram.keyzones.isEmpty && anchorKeyzoneIndex != nil {
                        PianoKeyboardView(
                            keyzones: editedProgram.keyzones,
                            selectedIndex: anchorKeyzoneIndex,
                            onKeyzoneChanged: { updated in
                                if let idx = anchorKeyzoneIndex, idx < editedProgram.keyzones.count {
                                    applyToSelectedKeyzones(updated, primaryIndex: idx)
                                    commitProgramEdits()
                                }
                            }
                        )
                        .frame(height: 140)
                        .background(Color(nsColor: .controlBackgroundColor))

                        if let idx = anchorKeyzoneIndex, idx < editedProgram.keyzones.count {
                            HStack {
                                MidiKeyPicker(label: "Low", value: keyzoneFieldBinding(idx, \.lowKey), onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "Root", value: keyzoneFieldBinding(idx, \.rootNote), onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "High", value: keyzoneFieldBinding(idx, \.highKey), onChange: { commitProgramEdits() })
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        Divider()
                    }

                    if let idx = anchorKeyzoneIndex, idx < editedProgram.keyzones.count {
                        KeyzoneEditorView(
                            keyzone: Binding(
                                get: { editedProgram.keyzones[idx] },
                                set: { newValue in applyToSelectedKeyzones(newValue, primaryIndex: idx) }
                            ),
                            selectedCount: selectedKeyzoneIndices.count,
                            modSource1: editedProgram.filterModSource1,
                            modSource2: editedProgram.filterModSource2,
                            modSource3: editedProgram.filterModSource3,
                            onChange: { commitProgramEdits() }
                        )
                        .padding()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                InfoCard(title: "Create Keyzone") {
                                    HStack(alignment: .top, spacing: 12) {
                                        PresetDropZone(
                                            diskImage: diskImage,
                                            existingKeyzones: editedProgram.keyzones,
                                            onSamplesImported: { newKeyzones in
                                                editedProgram.keyzones.append(contentsOf: newKeyzones)
                                                let newIdx = editedProgram.keyzones.count - 1
                                                selectedKeyzoneIndices = [newIdx]
                                                anchorKeyzoneIndex = newIdx
                                                commitProgramEdits()
                                            }
                                        )
                                        DrumPresetDropZone(
                                            diskImage: diskImage,
                                            existingKeyzones: editedProgram.keyzones,
                                            onSamplesImported: { newKeyzones in
                                                editedProgram.keyzones.append(contentsOf: newKeyzones)
                                                let newIdx = editedProgram.keyzones.count - 1
                                                selectedKeyzoneIndices = [newIdx]
                                                anchorKeyzoneIndex = newIdx
                                                commitProgramEdits()
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(16)
                        }
                    } // end else (no keyzone selected)
                } // end right-panel VStack
            } // end HSplitView
        } // end body VStack
        .onChange(of: isDirty) { _, dirty in
            if dirty { diskImage.hasUnsavedChanges = true }
        }
        .confirmationDialog(
            selectedKeyzoneIndices.count > 1 ? "Delete \(selectedKeyzoneIndices.count) keyzones?" : "Delete this keyzone?",
            isPresented: $showDeleteKeyzoneConfirm,
            titleVisibility: .visible
        ) {
            Button(selectedKeyzoneIndices.count > 1 ? "Delete \(selectedKeyzoneIndices.count) Keyzones" : "Delete Keyzone", role: .destructive) {
                deleteSelectedKeyzones()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the keyzone\(selectedKeyzoneIndices.count > 1 ? "s" : "") from the program. The disk image file is not modified until you save.")
        }
        .toast($toast)
    }

    private func beginRename() {
        editedName = currentName; isEditingName = true; diskImage.isEditingText = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }
    private func cancelRename() {
        isEditingName = false; nameFieldFocused = false; diskImage.isEditingText = false
    }
    private func commitRename() {
        let clean = AkaiDiskImage.sanitizeName(editedName)
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if clean == currentName { isEditingName = false; nameFieldFocused = false; diskImage.isEditingText = false; return }
        do {
            try diskImage.renameProgram(id: programFile.id, to: clean)
            editedProgram.name = clean
            isEditingName = false; nameFieldFocused = false; diskImage.isEditingText = false
            toast = ToastData(message: "Renamed to \(clean)")
        } catch { toast = ToastData(message: error.localizedDescription, isError: true) }
    }
    private func addKeyzone() {
        let newKZ = AkaiProgramKeyzone(
            sampleName: diskImage.samples.first?.header.name ?? "NO NAME",
            lowKey: 24, highKey: 127, rootNote: 60,
            tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
            filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
            filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
            rightSampleName: "", rightPan: 50, playbackMode: .sample, velocityLow: 0, velocityHigh: 127)
        editedProgram.keyzones.append(newKZ)
        let newIdx = editedProgram.keyzones.count - 1
        selectedKeyzoneIndices = [newIdx]; anchorKeyzoneIndex = newIdx
        commitProgramEdits()
    }
    private func cloneKeyzone(at index: Int) {
        guard editedProgram.keyzones.indices.contains(index) else { return }
        let copy = editedProgram.keyzones[index]
        let insertAt = index + 1
        editedProgram.keyzones.insert(copy, at: insertAt)
        selectedKeyzoneIndices = [insertAt]; anchorKeyzoneIndex = insertAt
        commitProgramEdits()
    }
    private func deleteSelectedKeyzones() {
        guard !selectedKeyzoneIndices.isEmpty else { return }
        let sortedIndices = selectedKeyzoneIndices.sorted()
        let firstRemoved = sortedIndices.first ?? 0
        for idx in sortedIndices.reversed() where editedProgram.keyzones.indices.contains(idx) {
            editedProgram.keyzones.remove(at: idx)
        }
        if editedProgram.keyzones.isEmpty { selectedKeyzoneIndices = []; anchorKeyzoneIndex = nil }
        else { let newIdx = min(firstRemoved, editedProgram.keyzones.count - 1); selectedKeyzoneIndices = [newIdx]; anchorKeyzoneIndex = newIdx }
        commitProgramEdits()
    }
    private func handleKeyzoneTap(_ idx: Int, shift: Bool, command: Bool) {
        if shift, let anchor = anchorKeyzoneIndex {
            let range = anchor <= idx ? anchor...idx : idx...anchor
            selectedKeyzoneIndices = Set(range)
        } else if command {
            if selectedKeyzoneIndices.contains(idx) { selectedKeyzoneIndices.remove(idx) } else { selectedKeyzoneIndices.insert(idx) }
            anchorKeyzoneIndex = idx
        } else {
            if selectedKeyzoneIndices == [idx] { selectedKeyzoneIndices = []; anchorKeyzoneIndex = nil }
            else { selectedKeyzoneIndices = [idx]; anchorKeyzoneIndex = idx }
        }
    }
    private func moveKeyzoneSelection(by delta: Int) {
        let count = editedProgram.keyzones.count; guard count > 0 else { return }
        let newIdx: Int
        if let idx = anchorKeyzoneIndex { newIdx = max(0, min(count - 1, idx + delta)) } else { newIdx = delta > 0 ? 0 : count - 1 }
        selectedKeyzoneIndices = [newIdx]; anchorKeyzoneIndex = newIdx
    }
    private func applyToSelectedKeyzones(_ newValue: AkaiProgramKeyzone, primaryIndex: Int) {
        guard editedProgram.keyzones.indices.contains(primaryIndex) else { return }
        let old = editedProgram.keyzones[primaryIndex]
        editedProgram.keyzones[primaryIndex] = newValue
        let others = selectedKeyzoneIndices.subtracting([primaryIndex]).filter { editedProgram.keyzones.indices.contains($0) }
        guard !others.isEmpty else { return }
        for idx in others {
            var kz = editedProgram.keyzones[idx]
            if old.lowKey != newValue.lowKey { kz.lowKey = newValue.lowKey }
            if old.highKey != newValue.highKey { kz.highKey = newValue.highKey }
            if old.rootNote != newValue.rootNote { kz.rootNote = newValue.rootNote }
            if old.tuneOffset != newValue.tuneOffset { kz.tuneOffset = newValue.tuneOffset }
            if old.fineTune != newValue.fineTune { kz.fineTune = newValue.fineTune }
            if old.volume != newValue.volume { kz.volume = newValue.volume }
            if old.pan != newValue.pan { kz.pan = newValue.pan }
            if old.filterOffset != newValue.filterOffset { kz.filterOffset = newValue.filterOffset }
            if old.filterCutoff != newValue.filterCutoff { kz.filterCutoff = newValue.filterCutoff }
            if old.filterKeyFollow != newValue.filterKeyFollow { kz.filterKeyFollow = newValue.filterKeyFollow }
            if old.filterResonance != newValue.filterResonance { kz.filterResonance = newValue.filterResonance }
            if old.filterModDepth1 != newValue.filterModDepth1 { kz.filterModDepth1 = newValue.filterModDepth1 }
            if old.filterModDepth2 != newValue.filterModDepth2 { kz.filterModDepth2 = newValue.filterModDepth2 }
            if old.filterModDepth3 != newValue.filterModDepth3 { kz.filterModDepth3 = newValue.filterModDepth3 }
            if old.playbackMode != newValue.playbackMode { kz.playbackMode = newValue.playbackMode }
            if old.velocityLow != newValue.velocityLow { kz.velocityLow = newValue.velocityLow }
            if old.velocityHigh != newValue.velocityHigh { kz.velocityHigh = newValue.velocityHigh }
            if old.env1Attack != newValue.env1Attack { kz.env1Attack = newValue.env1Attack }
            if old.env1Decay != newValue.env1Decay { kz.env1Decay = newValue.env1Decay }
            if old.env1Sustain != newValue.env1Sustain { kz.env1Sustain = newValue.env1Sustain }
            if old.env1Release != newValue.env1Release { kz.env1Release = newValue.env1Release }
            if old.env2R1 != newValue.env2R1 { kz.env2R1 = newValue.env2R1 }
            if old.env2L1 != newValue.env2L1 { kz.env2L1 = newValue.env2L1 }
            if old.env2R2 != newValue.env2R2 { kz.env2R2 = newValue.env2R2 }
            if old.env2L2 != newValue.env2L2 { kz.env2L2 = newValue.env2L2 }
            if old.env2R3 != newValue.env2R3 { kz.env2R3 = newValue.env2R3 }
            if old.env2L3 != newValue.env2L3 { kz.env2L3 = newValue.env2L3 }
            if old.env2R4 != newValue.env2R4 { kz.env2R4 = newValue.env2R4 }
            if old.env2L4 != newValue.env2L4 { kz.env2L4 = newValue.env2L4 }
            editedProgram.keyzones[idx] = kz
        }
    }
    private func keyzoneFieldBinding(_ idx: Int, _ keyPath: WritableKeyPath<AkaiProgramKeyzone, UInt8>) -> Binding<UInt8> {
        Binding(
            get: { editedProgram.keyzones.indices.contains(idx) ? editedProgram.keyzones[idx][keyPath: keyPath] : 0 },
            set: { newVal in
                guard editedProgram.keyzones.indices.contains(idx) else { return }
                var updated = editedProgram.keyzones[idx]
                updated[keyPath: keyPath] = newVal
                applyToSelectedKeyzones(updated, primaryIndex: idx)
            }
        )
    }
    private func commitProgramEdits() {
        isDirty = true
        var updated = diskImage.programs.first(where: { $0.id == programFile.id }) ?? programFile
        updated.program = editedProgram
        diskImage.applyProgramEdits(updated)
    }
    private func toggleSample(_ name: String) {
        guard let idx = anchorKeyzoneIndex, editedProgram.keyzones.indices.contains(idx) else { return }
        if editedProgram.keyzones[idx].sampleName == name { editedProgram.keyzones[idx].sampleName = "" }
        else { editedProgram.keyzones[idx].sampleName = name }
        commitProgramEdits()
    }
    private func toggleRightSample(_ name: String) {
        guard let idx = anchorKeyzoneIndex, editedProgram.keyzones.indices.contains(idx) else { return }
        if editedProgram.keyzones[idx].rightSampleName == name {
            editedProgram.keyzones[idx].rightSampleName = ""
            if editedProgram.keyzones[idx].pan == -50 { editedProgram.keyzones[idx].pan = 0 }
        } else {
            editedProgram.keyzones[idx].rightSampleName = name
            editedProgram.keyzones[idx].rightPan = 50
            if editedProgram.keyzones[idx].pan == 0 { editedProgram.keyzones[idx].pan = -50 }
        }
        commitProgramEdits()
    }
    @ViewBuilder
    private func samplePill(for sample: AkaiSample) -> some View {
        let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
        let hasSelection = anchorKeyzoneIndex != nil
        let isAssigned = anchorKeyzoneIndex.flatMap { idx in
            editedProgram.keyzones.indices.contains(idx) ? editedProgram.keyzones[idx].sampleName == name : nil
        } ?? false
        Text(name)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isAssigned ? .white : .primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isAssigned ? Color.red : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isAssigned ? Color.clear : Color.secondary.opacity(0.35)))
            .opacity(hasSelection ? 1 : 0.45).contentShape(Capsule())
            .onTapGesture { if hasSelection { toggleSample(name) } }
            .help(hasSelection ? (isAssigned ? "Remove from this keyzone" : "Assign to this keyzone") : "Select a keyzone first")
    }
    @ViewBuilder
    private func rightSamplePill(for sample: AkaiSample) -> some View {
        let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
        let hasSelection = anchorKeyzoneIndex != nil
        let isAssigned = anchorKeyzoneIndex.flatMap { idx in
            editedProgram.keyzones.indices.contains(idx) ? editedProgram.keyzones[idx].rightSampleName == name : nil
        } ?? false
        Text(name)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isAssigned ? .white : .primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isAssigned ? Color.blue : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isAssigned ? Color.clear : Color.secondary.opacity(0.35)))
            .opacity(hasSelection ? 1 : 0.45).contentShape(Capsule())
            .onTapGesture { if hasSelection { toggleRightSample(name) } }
            .help(hasSelection ? (isAssigned ? "Remove stereo right channel" : "Assign as stereo right channel (zone 2)") : "Select a keyzone first")
    }
}

// MARK: - Preset Drop Zone

struct PresetDropZone: View {
    @ObservedObject var diskImage: AkaiDiskImage
    let existingKeyzones: [AkaiProgramKeyzone]
    let onSamplesImported: ([AkaiProgramKeyzone]) -> Void
    @State private var isDragging = false
    @State private var isImporting = false
    @State private var errorMessage: String? = nil
    private let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map to full keyboard").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDragging ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDragging ? Color.blue.opacity(0.6) : Color.secondary.opacity(0.2),
                                  style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [6]))
                VStack(spacing: 8) {
                    if isImporting {
                        ProgressView("Importing...").padding()
                    } else {
                        Button { openSamples() } label: {
                            Label("Browse Samples", systemImage: "square.and.arrow.down.on.square")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(.white).background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).padding(.horizontal, 12)
                        Text("or drag .wav / sidebar samples here").font(.caption).foregroundStyle(.tertiary)
                        Divider().padding(.horizontal, 12)
                        Label("One sample mapped across C0–G8.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .onDrop(of: [.fileURL, .plainText], isTargeted: $isDragging) { providers in
                if let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) {
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        guard let name = string as? String,
                              let sample = self.diskImage.samples.first(where: {
                                  ($0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name) == name
                              }) else { return }
                        DispatchQueue.main.async { self.addKeyzoneFromSample(sample) }
                    }
                    return true
                }
                handleDrop(providers: providers)
                return true
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func addKeyzoneFromSample(_ sample: AkaiSample) {
        let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
        let note = UInt8(min(24 + existingKeyzones.count, 127))
        let kz = AkaiProgramKeyzone(
            sampleName: name, lowKey: 24, highKey: 127, rootNote: note,
            tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
            filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
            filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
            rightSampleName: "", rightPan: 50, playbackMode: .sample, velocityLow: 0, velocityHigh: 127)
        onSamplesImported([kz])
    }
    private func openSamples() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]; panel.title = "Choose samples for preset"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []; let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      audioExts.contains(url.pathExtension.lowercased()) else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) { importURLs(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
    }
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true; errorMessage = nil
        var newKeyzones: [AkaiProgramKeyzone] = []; var errors: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let wavData = try Data(contentsOf: url)
                    let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
                    let baseName = AkaiDiskImage.sanitizeName(url.deletingPathExtension().lastPathComponent)
                    let monoData: Data; let monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left; monoName = String(baseName.prefix(10)) + "-L"
                    } else { monoData = pcmData; monoName = baseName }
                    let sample = try diskImage.addImportedSample(name: monoName, sampleRate: UInt32(sampleRate), numChannels: 1, pcmData: monoData)
                    let note = UInt8(min(24 + existingKeyzones.count + newKeyzones.count, 127))
                    newKeyzones.append(AkaiProgramKeyzone(
                        sampleName: sample.header.name, lowKey: 24, highKey: 127, rootNote: note,
                        tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                        filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                        filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                        rightSampleName: "", rightPan: 50, playbackMode: .sample, velocityLow: 0, velocityHigh: 127))
                } catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            DispatchQueue.main.async {
                isImporting = false
                if !newKeyzones.isEmpty { onSamplesImported(newKeyzones) }
                if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
            }
        }
    }
    private func parseWAV(_ data: Data) throws -> (Data, Int, Int, Int) {
        guard data.count > 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw NSError(domain: "WAV", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not a valid WAV file"])
        }
        var offset = 12, sampleRate = 44100, numChannels = 1, bitsPerSample = 16; var pcmData = Data()
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(data.readLE32(at: offset + 4)); offset += 8
            if id == "fmt " { numChannels = Int(data.readLE16(at: offset+2)); sampleRate = Int(data.readLE32(at: offset+4)); bitsPerSample = Int(data.readLE16(at: offset+14)) }
            else if id == "data" { pcmData = data.subdata(in: offset..<min(offset+size, data.count)) }
            offset += size + (size % 2)
        }
        guard !pcmData.isEmpty else { throw NSError(domain: "WAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio data in WAV"]) }
        return (pcmData, sampleRate, numChannels, bitsPerSample)
    }
}

// MARK: - Drum Preset Drop Zone

struct DrumPresetDropZone: View {
    @ObservedObject var diskImage: AkaiDiskImage
    let existingKeyzones: [AkaiProgramKeyzone]
    let onSamplesImported: ([AkaiProgramKeyzone]) -> Void
    @State private var isDragging = false
    @State private var isImporting = false
    @State private var errorMessage: String? = nil
    private let akaiRed = Color(red: 0.91, green: 0, blue: 0.11)
    private let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map to individual keys").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isDragging ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDragging ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.2),
                                  style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [6]))
                VStack(spacing: 8) {
                    if isImporting {
                        ProgressView("Importing samples...").padding()
                    } else {
                        Button { openSamples() } label: {
                            Label("Browse Drum Samples", systemImage: "square.grid.2x2.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(.white).background(akaiRed)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).padding(.horizontal, 12)
                        Text("or drag .wav / sidebar samples here").font(.caption).foregroundStyle(.tertiary)
                        Divider().padding(.horizontal, 12)
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Each sample mapped to its own key from C0 upwards.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                            Label("Stereo: left channel only.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .onDrop(of: [.fileURL, .plainText], isTargeted: $isDragging) { providers in
                if let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) {
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        guard let name = string as? String else { return }
                        guard self.diskImage.samples.contains(where: {
                            ($0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name) == name
                        }) else { return }
                        DispatchQueue.main.async {
                            let note = UInt8(min(24 + self.existingKeyzones.count, 127))
                            let kz = AkaiProgramKeyzone(
                                sampleName: name, lowKey: note, highKey: note, rootNote: note,
                                tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                                filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                                filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                                rightSampleName: "", rightPan: 50, playbackMode: .noLoop, velocityLow: 0, velocityHigh: 127)
                            self.onSamplesImported([kz])
                        }
                    }
                    return true
                }
                handleDrop(providers: providers)
                return true
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func openSamples() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]; panel.title = "Choose samples for drum preset"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []; let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      audioExts.contains(url.pathExtension.lowercased()) else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) { importURLs(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
    }
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true; errorMessage = nil
        var newKeyzones: [AkaiProgramKeyzone] = []
        var nextNote: Int = existingKeyzones.last.map { Int($0.rootNote) + 1 } ?? 24
        var errors: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let wavData = try Data(contentsOf: url)
                    let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
                    let baseName = AkaiDiskImage.sanitizeName(url.deletingPathExtension().lastPathComponent)
                    let monoData: Data; let monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left; monoName = String(baseName.prefix(10)) + "-L"
                    } else { monoData = pcmData; monoName = baseName }
                    let sample = try diskImage.addImportedSample(name: monoName, sampleRate: UInt32(sampleRate), numChannels: 1, pcmData: monoData)
                    let note = UInt8(min(nextNote, 127))
                    newKeyzones.append(AkaiProgramKeyzone(
                        sampleName: sample.header.name, lowKey: note, highKey: note, rootNote: note,
                        tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                        filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                        filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                        rightSampleName: "", rightPan: 50, playbackMode: .noLoop, velocityLow: 0, velocityHigh: 127))
                    nextNote += 1
                } catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            DispatchQueue.main.async {
                isImporting = false
                if !newKeyzones.isEmpty { onSamplesImported(newKeyzones) }
                if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
            }
        }
    }
    private func parseWAV(_ data: Data) throws -> (Data, Int, Int, Int) {
        guard data.count > 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw NSError(domain: "WAV", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not a valid WAV file"])
        }
        var offset = 12, sampleRate = 44100, numChannels = 1, bitsPerSample = 16; var pcmData = Data()
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(data.readLE32(at: offset + 4)); offset += 8
            if id == "fmt " { numChannels = Int(data.readLE16(at: offset+2)); sampleRate = Int(data.readLE32(at: offset+4)); bitsPerSample = Int(data.readLE16(at: offset+14)) }
            else if id == "data" { pcmData = data.subdata(in: offset..<min(offset+size, data.count)) }
            offset += size + (size % 2)
        }
        guard !pcmData.isEmpty else { throw NSError(domain: "WAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio data in WAV"]) }
        return (pcmData, sampleRate, numChannels, bitsPerSample)
    }
}

// MARK: - Keyzone Row

struct KeyzoneRow: View {
    let keyzone: AkaiProgramKeyzone
    let sampleNames: [String]
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.7)).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : keyzone.sampleName)
                        .font(.system(.body, design: .monospaced)).lineLimit(1)
                    if !keyzone.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("L+R").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.2))).foregroundStyle(.blue)
                            .help("Stereo pair: zone 2 = \(keyzone.rightSampleName.trimmingCharacters(in: .whitespaces))")
                    }
                }
                HStack(spacing: 8) {
                    Text("\(midiNoteName(keyzone.lowKey))–\(midiNoteName(keyzone.highKey))").font(.caption).foregroundStyle(.secondary)
                    Text("Root: \(midiNoteName(keyzone.rootNote))").font(.caption).foregroundStyle(.blue)
                    Text("Vel: \(keyzone.velocityLow)–\(keyzone.velocityHigh)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 2).contentShape(Rectangle())
    }
    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
    }
}

// MARK: - Keyzone Editor

struct KeyzoneEditorView: View {
    @Binding var keyzone: AkaiProgramKeyzone
    var selectedCount: Int = 1
    var modSource1: AkaiFilterModSource = .velocity
    var modSource2: AkaiFilterModSource = .lfo2
    var modSource3: AkaiFilterModSource = .env2
    let onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyzone Settings").font(.headline)
                    if selectedCount > 1 {
                        Spacer()
                        Text("Editing \(selectedCount) keygroups — changes apply to all selected")
                            .font(.caption).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                InfoCard(title: "Playback") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Playback Mode").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $keyzone.playbackMode) {
                                ForEach(AkaiPlaybackMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                            }
                            .labelsHidden().onChange(of: keyzone.playbackMode) { _, _ in onChange() }
                            Spacer()
                        }
                        Text(keyzone.playbackMode.explanation).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.leading, 100)
                    }
                }
                InfoCard(title: "Tune") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tune (st)").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Stepper("\(keyzone.tuneOffset)", value: $keyzone.tuneOffset, in: -24...24)
                                .onChange(of: keyzone.tuneOffset) { _, _ in onChange() }
                        }
                        HStack {
                            Text("Fine (¢)").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.fineTune) }, set: { keyzone.fineTune = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text("\(keyzone.fineTune)¢").frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Volume").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.volume) }, set: { keyzone.volume = UInt8($0); onChange() }), in: 0...99, step: 1)
                            Text("\(keyzone.volume)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.pan) }, set: { keyzone.pan = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text(keyzone.pan == 0 ? "C" : keyzone.pan > 0 ? "R\(keyzone.pan)" : "L\(abs(keyzone.pan))")
                                .frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        if !keyzone.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Right Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                    Slider(value: .init(get: { Double(keyzone.rightPan) }, set: { keyzone.rightPan = Int8($0); onChange() }), in: -50...50, step: 1)
                                    Text(keyzone.rightPan == 0 ? "C" : keyzone.rightPan > 0 ? "R\(keyzone.rightPan)" : "L\(abs(keyzone.rightPan))")
                                        .frame(width: 35).font(.system(.caption, design: .monospaced))
                                }
                                Text("Pan for the stereo right channel (zone 2: \(keyzone.rightSampleName.trimmingCharacters(in: .whitespaces))). Real hardware convention is hard left/right (-50/+50).")
                                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 100)
                            }
                        }
                    }
                }
                InfoCard(title: "Velocity") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Low Velocity").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.velocityLow) }, set: { keyzone.velocityLow = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityLow)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("High Velocity").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.velocityHigh) }, set: { keyzone.velocityHigh = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityHigh)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                InfoCard(title: "ENV1 — Shaping Amplitude") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Controls the volume shape of each note over time. Attack sets how quickly the sound reaches full volume; Decay how quickly it falls to the Sustain level; Sustain the held level while the key is held; Release how quickly it fades after key release. (Manual p.105)")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .center, spacing: 12) {
                            AdsrView(
                                attack: Binding(get: { keyzone.env1Attack }, set: { keyzone.env1Attack = $0; onChange() }),
                                decay: Binding(get: { keyzone.env1Decay }, set: { keyzone.env1Decay = $0; onChange() }),
                                sustain: Binding(get: { keyzone.env1Sustain }, set: { keyzone.env1Sustain = $0; onChange() }),
                                release: Binding(get: { keyzone.env1Release }, set: { keyzone.env1Release = $0; onChange() })
                            ).frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                EnvSlider(label: "Attack", value: Binding(get: { keyzone.env1Attack }, set: { keyzone.env1Attack = $0; onChange() }), caption: "How quickly the sound reaches full volume on note-on. 0 = instant, 99 = slow fade in.")
                                EnvSlider(label: "Decay", value: Binding(get: { keyzone.env1Decay }, set: { keyzone.env1Decay = $0; onChange() }), caption: "How quickly the volume falls from the attack peak to the Sustain level.")
                                EnvSlider(label: "Sustain", value: Binding(get: { keyzone.env1Sustain }, set: { keyzone.env1Sustain = $0; onChange() }), caption: "Volume level held while the key is down. 0 = silent, 99 = full level.")
                                EnvSlider(label: "Release", value: Binding(get: { keyzone.env1Release }, set: { keyzone.env1Release = $0; onChange() }), caption: "How quickly the sound fades after key release. 0 = instant cutoff, 99 = long fade.")
                            }.frame(maxWidth: .infinity)
                        }
                        HStack {
                            Button {
                                keyzone.env1Attack = AkaiKeyzoneDefaults.env1Attack; keyzone.env1Decay = AkaiKeyzoneDefaults.env1Decay
                                keyzone.env1Sustain = AkaiKeyzoneDefaults.env1Sustain; keyzone.env1Release = AkaiKeyzoneDefaults.env1Release
                                onChange()
                            } label: { Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 11)) }
                            .buttonStyle(.bordered).controlSize(.small).tint(.blue)
                            .help("Reset ENV1 to hardware defaults: A=\(AkaiKeyzoneDefaults.env1Attack) D=\(AkaiKeyzoneDefaults.env1Decay) S=\(AkaiKeyzoneDefaults.env1Sustain) R=\(AkaiKeyzoneDefaults.env1Release)")
                            Spacer()
                        }
                    }
                }
                InfoCard(title: "Filter") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Frequency").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterCutoff) }, set: { keyzone.filterCutoff = UInt8($0); onChange() }), in: 0...99, step: 1)
                                Text("\(keyzone.filterCutoff)").frame(width: 30).font(.system(.body, design: .monospaced))
                            }
                            Text("Cutoff frequency of the 12dB/octave resonant lowpass filter. 99 = fully open (no filtering); lower values progressively remove high frequencies, darkening the tone.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Key Follow").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Stepper("\(keyzone.filterKeyFollow)", value: $keyzone.filterKeyFollow, in: -24...24)
                                    .onChange(of: keyzone.filterKeyFollow) { _, _ in onChange() }
                            }
                            Text("How much the cutoff tracks keyboard position. 0 = no tracking; +12 = filter opens one octave for every octave played up the keyboard.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Resonance").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterResonance) }, set: { keyzone.filterResonance = UInt8($0); onChange() }), in: 0...15, step: 1)
                                Text("\(keyzone.filterResonance)").frame(width: 30).font(.system(.body, design: .monospaced))
                            }
                            Text("Narrows the filter's response slope, emphasising harmonics around the cutoff frequency. High settings produce a resonant 'weeow' character.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource1.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth1) }, set: { keyzone.filterModDepth1 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth1)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source opens/closes the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource2.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth2) }, set: { keyzone.filterModDepth2 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth2)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source sweeps the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource3.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth3) }, set: { keyzone.filterModDepth3 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth3)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source shapes the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Filter Trim").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterOffset) }, set: { keyzone.filterOffset = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterOffset)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("Small ±50 adjustment on top of Cutoff, for matching tone between adjacent keygroups.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                    }
                }
                InfoCard(title: "ENV2 — Shaping The Filter") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Controls how the filter cutoff changes over time. ENV2 is a 4-stage Rate/Level envelope: R1→L1, R2→L2, R3→L3 (sustain), R4→L4. Works with the filter mod depth above. (Manual p.107)")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .center, spacing: 12) {
                            AdsrView(
                                attack: Binding(get: { keyzone.env2R1 }, set: { keyzone.env2R1 = $0; onChange() }),
                                decay: Binding(get: { keyzone.env2R2 }, set: { keyzone.env2R2 = $0; onChange() }),
                                sustain: Binding(get: { keyzone.env2L3 }, set: { keyzone.env2L3 = $0; onChange() }),
                                release: Binding(get: { keyzone.env2R4 }, set: { keyzone.env2R4 = $0; onChange() }),
                                color: .orange
                            ).frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                EnvSlider(label: "R1", value: Binding(get: { keyzone.env2R1 }, set: { keyzone.env2R1 = $0; onChange() }), caption: "Rate 1: how quickly the filter opens on note-on.")
                                EnvSlider(label: "L1", value: Binding(get: { keyzone.env2L1 }, set: { keyzone.env2L1 = $0; onChange() }), caption: "Level 1: the peak level reached after Rate 1.")
                                EnvSlider(label: "R2", value: Binding(get: { keyzone.env2R2 }, set: { keyzone.env2R2 = $0; onChange() }), caption: "Rate 2: how quickly it falls from L1 to L2.")
                                EnvSlider(label: "L2", value: Binding(get: { keyzone.env2L2 }, set: { keyzone.env2L2 = $0; onChange() }), caption: "Level 2: intermediate level.")
                                EnvSlider(label: "R3", value: Binding(get: { keyzone.env2R3 }, set: { keyzone.env2R3 = $0; onChange() }), caption: "Rate 3: how quickly it moves from L2 to L3.")
                                EnvSlider(label: "L3", value: Binding(get: { keyzone.env2L3 }, set: { keyzone.env2L3 = $0; onChange() }), caption: "Level 3: sustain level held while key is pressed.")
                                EnvSlider(label: "R4", value: Binding(get: { keyzone.env2R4 }, set: { keyzone.env2R4 = $0; onChange() }), caption: "Rate 4: how quickly the filter closes after key release.")
                                EnvSlider(label: "L4", value: Binding(get: { keyzone.env2L4 }, set: { keyzone.env2L4 = $0; onChange() }), caption: "Level 4: final level after release.")
                            }.frame(maxWidth: .infinity)
                        }
                        HStack {
                            Button {
                                keyzone.env2R1 = AkaiKeyzoneDefaults.env2R1; keyzone.env2L1 = AkaiKeyzoneDefaults.env2L1
                                keyzone.env2R2 = AkaiKeyzoneDefaults.env2R2; keyzone.env2L2 = AkaiKeyzoneDefaults.env2L2
                                keyzone.env2R3 = AkaiKeyzoneDefaults.env2R3; keyzone.env2L3 = AkaiKeyzoneDefaults.env2L3
                                keyzone.env2R4 = AkaiKeyzoneDefaults.env2R4; keyzone.env2L4 = AkaiKeyzoneDefaults.env2L4
                                onChange()
                            } label: { Label("Reset", systemImage: "arrow.counterclockwise").font(.system(size: 11)) }
                            .buttonStyle(.bordered).controlSize(.small).tint(.blue)
                            .help("Reset ENV2 to hardware defaults: R1=\(AkaiKeyzoneDefaults.env2R1) L1=\(AkaiKeyzoneDefaults.env2L1) R2=\(AkaiKeyzoneDefaults.env2R2) L2=\(AkaiKeyzoneDefaults.env2L2) R3=\(AkaiKeyzoneDefaults.env2R3) L3=\(AkaiKeyzoneDefaults.env2L3) R4=\(AkaiKeyzoneDefaults.env2R4) L4=\(AkaiKeyzoneDefaults.env2L4)")
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Round Icon Button

struct RoundIconButton: View {
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(isDisabled).opacity(isDisabled ? 0.4 : 1)
    }
}

// MARK: - MIDI Key Picker

struct MidiKeyPicker: View {
    let label: String
    @Binding var value: UInt8
    let onChange: () -> Void
    private static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading).font(.subheadline)
            Picker("", selection: $value) {
                ForEach((0..<128).reversed(), id: \.self) { note in Text(noteName(UInt8(note))).tag(UInt8(note)) }
            }
            .labelsHidden().onChange(of: value) { _, _ in onChange() }
        }
    }
    private func noteName(_ note: UInt8) -> String {
        "\(Self.noteNames[Int(note) % 12])\(Int(note) / 12 - 2) (\(note))"
    }
}

// MARK: - Program List

struct ProgramListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedProgramID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Programs").font(.title2.bold())
                Spacer()
                Text("\(diskImage.programs.count) files").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if diskImage.programs.isEmpty {
                ContentUnavailableView("No Programs", systemImage: "pianokeys",
                    description: Text("This disk image contains no program files."))
            } else {
                Table(diskImage.programs, selection: $selectedProgramID) {
                    TableColumn("Name") { p in
                        Text(p.program.name.isEmpty ? p.directoryEntry.name : p.program.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Keyzones") { p in Text("\(p.program.keyzones.count)") }.width(80)
                    TableColumn("MIDI Ch.") { p in
                        Text(p.program.midiChannel == 0 ? "All" : "\(p.program.midiChannel)")
                    }.width(70)
                    TableColumn("Polyphony") { p in Text("\(p.program.polyphony)") }.width(80)
                }
            }
        }
    }
}
