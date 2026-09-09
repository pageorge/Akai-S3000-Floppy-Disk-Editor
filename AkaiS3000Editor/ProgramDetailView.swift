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
    @State private var showDropError = false
    @State private var dropErrorMessage = ""
    /// Highlights the "Add Samples" drop zone while a file/folder is dragged over
    /// the program view. Bound to the whole-view .onDrop's isTargeted.
    @State private var dropTargeted = false
    private let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]
    @AppStorage("lowQualityImport") private var lowQualityImport = false
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
                            Image(systemName: editedProgram.isDrumKit ? drumKitSymbol : "pianokeys")
                                .font(.system(size: 20))
                                .foregroundStyle(editedProgram.isDrumKit ? akaiDrumBrown : .purple)
                            Text(currentName)
                                .font(.system(.title, design: .monospaced).bold())
                                .textSelection(.enabled)
                            Button { beginRename() } label: {
                                Image(systemName: "pencil").font(.system(size: 14))
                            }
                            .buttonStyle(.borderless).help("Rename program")
                        }
                    }
                    Text(editedProgram.isDrumKit
                         ? "Drum Program · \(editedProgram.keyzones.count) keys"
                         : "Program · \(editedProgram.keyzones.count) keyzones")
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
                                Label("Reset to Akai Defaults", systemImage: "arrow.counterclockwise").font(.system(size: 11))
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keyzones")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
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
                                        Label("Create Keyzone", systemImage: "plus.square.on.square")
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
                    .onChange(of: selectedKeyzoneIndices) { _, newValue in
                        // Mirrors the shared diskImage.isEditingText flag — lets
                        // SidebarView's own key monitor know to yield arrow/delete
                        // keys to THIS list instead of the sidebar's own selection.
                        // See AkaiDiskImage.keyzoneEditorActive's doc comment.
                        diskImage.keyzoneEditorActive = !newValue.isEmpty
                    }
                    .onAppear {
                        diskImage.keyzoneEditorActive = !selectedKeyzoneIndices.isEmpty
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
                        diskImage.keyzoneEditorActive = false
                    }
                        } // VStack inside Keyzones container
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                        .frame(maxHeight: .infinity)
                    } // Keyzones container (plain VStack, not GroupBox/InfoCard —
                      // GroupBox doesn't reliably propagate a bounded height to its
                      // content, so with many keyzones the List never gets a fixed
                      // frame to scroll within and the whole pane just grows past
                      // the window instead of scrolling internally.)
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
                                // Root note is the sample's rkey — read-only since
                        // keyzone rootNote is not written to disk (it's a UI
                        // field only; the sample's rkey controls pitch in TRACK).
                        let sampleRkey: UInt8 = {
                            let kzName = editedProgram.keyzones[idx].sampleName
                            return diskImage.samples.first(where: {
                                ($0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name) == kzName
                            })?.header.midiRootNote ?? editedProgram.keyzones[idx].rootNote
                        }()
                        HStack {
                            Text("Root").frame(width: 80, alignment: .leading).font(.subheadline)
                            Text(midiNoteNameStatic(sampleRkey))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("(sample root)").font(.caption).foregroundStyle(.tertiary)
                        }
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
                                InfoCard(title: "Add Samples") {
                                    SimpleDropZone(isTargeted: dropTargeted)
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
        .onDrop(of: [.fileURL, .plainText], isTargeted: $dropTargeted) { providers in
            handleProgramDrop(providers: providers)
        }
        .alert("Import error", isPresented: $showDropError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropErrorMessage)
        }
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
        let sampleName = diskImage.samples.first?.header.name ?? "NO NAME"
        let newKZ: AkaiProgramKeyzone
        if editedProgram.isDrumKit {
            // Drum program: single key, continuing +1 from the last single-key
            // zone (C1/36 if none). TRACK pitch with rootNote == key so the pad
            // plays at unity pitch AND responds to pitch bend (CONST would pin
            // pitch to C3 and ignore bend).
            let nextNote: Int
            if let last = editedProgram.keyzones.last, last.lowKey == last.highKey {
                nextNote = Int(last.highKey) + 1
            } else {
                nextNote = 36
            }
            let note = UInt8(min(nextNote, 127))
            newKZ = AkaiProgramKeyzone(
                sampleName: sampleName,
                lowKey: note, highKey: note, rootNote: 60,
                tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                rightSampleName: "", rightPan: 50, playbackMode: .sample,
                velocityLow: 0, velocityHigh: 127,
                env1Attack: 0, env1Decay: 0, env1Sustain: 99, env1Release: 0, pitchMode: 0)
        } else {
            // Melodic program: one zone across the whole visible keyboard.
            newKZ = AkaiProgramKeyzone(
                sampleName: sampleName,
                lowKey: 24, highKey: UInt8(PianoKeyboardView.visibleEndNote), rootNote: 60,
                tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                rightSampleName: "", rightPan: 50, playbackMode: .sample, velocityLow: 0, velocityHigh: 127)
        }
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
            if old.pitchMode != newValue.pitchMode { kz.pitchMode = newValue.pitchMode }
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
    private func midiNoteNameStatic(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
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
    // MARK: - Drop handling

    private func handleProgramDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Sidebar-sample drag: carries plain text (the sample name), NOT a file
        // URL. Per the simplified model, dragging an existing sample onto a
        // program only ever adds it drum-style — one key, continuing +1 from the
        // last mapped key.
        if provider.hasItemConformingToTypeIdentifier("public.plain-text") &&
           !provider.hasItemConformingToTypeIdentifier("public.file-url") {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let name = string as? String else { return }
                DispatchQueue.main.async { addKeyzoneFromDraggedSample(named: String(name)) }
            }
            return true
        }
        provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            DispatchQueue.main.async {
                if isDir.boolValue {
                    dropFolder(url)
                } else if audioExts.contains(url.pathExtension.lowercased()) {
                    dropFile(url)
                } else {
                    dropErrorMessage = "\(url.lastPathComponent) is not a supported audio file."
                    showDropError = true
                }
            }
        }
        return true
    }

    /// Add an already-imported sidebar sample as a keyzone. Behaviour depends on
    /// the program type: a DRUM program (isDrumKit) gets a single-key zone
    /// continuing +1 from the last key (C1/36 if none), Const pitch, no loop —
    /// stacking one-shot per key. A normal/melodic program gets ONE zone mapped
    /// across the whole visible keyboard (24…visibleEndNote), Track pitch, so it
    /// plays as a pitched instrument. The sample already exists on disk, so its
    /// header is left untouched — only a keyzone referencing it by name is added.
    private func addKeyzoneFromDraggedSample(named name: String) {
        guard diskImage.samples.contains(where: {
            ($0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name) == name
        }) else { return }

        let kz: AkaiProgramKeyzone
        let isDrum = editedProgram.isDrumKit || diskImage.isDrumProgram(name: currentName)
        if isDrum {
            // Single key, continuing +1 from the last single-key zone (C1/36 if none).
            // No seed keyzone exists to fill — the first drag just appends at C1.
            let nextNote: Int
            if let last = editedProgram.keyzones.last, last.lowKey == last.highKey {
                nextNote = Int(last.highKey) + 1
            } else {
                nextNote = 36
            }
            let note = UInt8(min(nextNote, 127))
            // Patch the sample's rkey to match the pad key so TRACK mode
            // plays at unity pitch (rkey=trigger = 1:1 ratio).
            if let sample = diskImage.samples.first(where: {
                ($0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name) == name
            }), sample.header.midiRootNote != note {
                let from = midiNoteNameStatic(sample.header.midiRootNote)
                let to = midiNoteNameStatic(note)
                var patched = sample
                patched.header.midiRootNote = note
                diskImage.applySampleEdits(patched)
                toast = ToastData(message: "\"\(name)\" root changed \(from) → \(to)")
            }
            kz = AkaiProgramKeyzone(
                sampleName: name, lowKey: note, highKey: note, rootNote: 60,
                tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                rightSampleName: "", rightPan: 50, playbackMode: .sample,
                velocityLow: 0, velocityHigh: 127,
                env1Attack: 0, env1Decay: 0, env1Sustain: 99, env1Release: 0, pitchMode: 0)
        } else {
            // Melodic: one zone across the whole visible keyboard, Track pitch.
            kz = AkaiProgramKeyzone(
                sampleName: name,
                lowKey: 24, highKey: UInt8(PianoKeyboardView.visibleEndNote), rootNote: 60,
                tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                rightSampleName: "", rightPan: 50, playbackMode: .sample,
                velocityLow: 0, velocityHigh: 127,
                env1Attack: 0, env1Decay: 0, env1Sustain: 99, env1Release: 0, pitchMode: 0)
        }
        editedProgram.keyzones.append(kz)
        let newIdx = editedProgram.keyzones.count - 1
        selectedKeyzoneIndices = [newIdx]
        anchorKeyzoneIndex = newIdx
        commitProgramEdits()
    }

    /// Determine the next key to use based on existing keyzones.
    /// If the last keyzone is a single key, return lastKey + 1.
    /// If the last keyzone is a full map, return another full map spanning the
    /// VISIBLE keyboard range (24…visibleEndNote), so a preset's top key matches
    /// what the piano view actually shows rather than extending to 127.
    private func nextDropKey() -> (low: UInt8, high: UInt8, root: UInt8, isSingle: Bool) {
        let top = UInt8(PianoKeyboardView.visibleEndNote)
        if let last = editedProgram.keyzones.last {
            if last.lowKey == last.highKey {
                // Single-key pattern — next key
                let next = UInt8(min(Int(last.highKey) + 1, 127))
                return (next, next, next, true)
            } else {
                // Full-map pattern — repeat full map across the visible range
                return (24, top, 60, false)
            }
        }
        // No keyzones yet — default to full map across the visible range
        return (24, top, 60, false)
    }

    private func dropFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        guard let wavData = try? Data(contentsOf: url) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        if accessing { url.stopAccessingSecurityScopedResource() }
        let decoded: WAVImport.Decoded
        do { decoded = try WAVImport.decode(wavData) }
        catch {
            dropErrorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            showDropError = true
            return
        }
        let pcmData = decoded.pcm
        let sampleRate = decoded.sampleRate
        let numChannels = decoded.channels
        let rawName = url.deletingPathExtension().lastPathComponent
        let isDrum = editedProgram.isDrumKit || diskImage.isDrumProgram(name: currentName)
        let keys: (low: UInt8, high: UInt8, root: UInt8, isSingle: Bool)
        if isDrum {
            // Drum: single key continuing from last, or C1 if empty
            let nextNote: Int
            if let last = editedProgram.keyzones.last, last.lowKey == last.highKey {
                nextNote = Int(last.highKey) + 1
            } else {
                nextNote = 36
            }
            let note = UInt8(min(nextNote, 127))
            keys = (note, note, 60, true)
        } else {
            keys = nextDropKey()
        }
        let loFi = lowQualityImport
        DispatchQueue.global(qos: .userInitiated).async {
        do {
        var monoData: Data; let monoName: String
        let rightData: Data?
        if numChannels >= 2 {
        let (left, right) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
        monoData = left
        // Drum programs: no -L suffix, no right channel
        monoName = isDrum
            ? AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))
            : AkaiDiskImage.sanitizeNamePreservingEnd(rawName, maxLen: 10) + "-L"
            rightData = isDrum ? nil : right
        } else {
        monoData = pcmData
            monoName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))
                            rightData = nil
                        }
                let finalRate: UInt32
                if loFi {
                    let (loPCM, loRate) = AkaiDiskImage.applyLoFi(pcm: monoData, fromRate: sampleRate)
                    monoData = loPCM; finalRate = loRate
                } else {
                    finalRate = UInt32(sampleRate)
                }
                let sample = try diskImage.addImportedSample(
                    name: monoName, sampleRate: finalRate, numChannels: 1, pcmData: monoData)
                // For drum programs: set sample rkey to match the pad key so
                // TRACK pitch plays at unity. rkey=C3 + trigger=C1 = 2 octaves
                // down (really slow). rkey=trigger = unity pitch on that pad.
                if isDrum {
                    var patched = sample
                    patched.header.midiRootNote = keys.low
                    diskImage.applySampleEdits(patched)
                }
                // For melodic programs, import right channel too.
                if !isDrum, numChannels >= 2, var r = rightData {
                    let stemR = AkaiDiskImage.sanitizeNamePreservingEnd(rawName, maxLen: 10) + "-R"
                    if loFi { r = AkaiDiskImage.applyLoFi(pcm: r, fromRate: sampleRate).0 }
                    _ = try? diskImage.addImportedSample(name: stemR, sampleRate: finalRate, numChannels: 1, pcmData: r)
                }
                let kz = AkaiProgramKeyzone(
                    sampleName: sample.header.name,
                    lowKey: keys.low, highKey: keys.high, rootNote: keys.root,
                    tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                    filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                    filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                    rightSampleName: "", rightPan: 50,
                    playbackMode: .sample,
                    velocityLow: 0, velocityHigh: 127,
                    pitchMode: 0)   // TRACK — root==key gives unity pitch, and
                                    // TRACK lets pitch bend affect the sample.
                DispatchQueue.main.async {
                    editedProgram.keyzones.append(kz)
                    let newIdx = editedProgram.keyzones.count - 1
                    selectedKeyzoneIndices = [newIdx]
                    anchorKeyzoneIndex = newIdx
                    commitProgramEdits()
                }
            } catch {
                DispatchQueue.main.async {
                    dropErrorMessage = error.localizedDescription
                    showDropError = true
                }
            }
        }
    }

    private func dropFolder(_ folderURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let audioURLs = contents
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !audioURLs.isEmpty else {
            dropErrorMessage = "No audio files found in \"\(folderURL.lastPathComponent)\"."
            showDropError = true
            return
        }
        // For folder drops always use single-key-per-sample mapping,
        // continuing from the last used key.
        var nextNote: Int
        if let last = editedProgram.keyzones.last {
            nextNote = last.lowKey == last.highKey ? Int(last.highKey) + 1 : 36
        } else {
            nextNote = 36
        }
        let loFi = lowQualityImport
        var usedNames = Set(diskImage.samples.map { $0.header.name })
        DispatchQueue.global(qos: .userInitiated).async {
            var newKeyzones: [AkaiProgramKeyzone] = []
            for url in audioURLs {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let wavData = try? Data(contentsOf: url),
                      let decoded = try? WAVImport.decode(wavData) else { continue }
                let pcmData = decoded.pcm
                let sampleRate = decoded.sampleRate
                let numChannels = decoded.channels
                let baseName = url.deletingPathExtension().lastPathComponent
                do {
                    var monoData: Data; var monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left; monoName = AkaiDiskImage.sanitizeNamePreservingEnd(baseName, maxLen: 10) + "-L"
                    } else {
                        monoData = pcmData; monoName = AkaiDiskImage.sanitizeName(String(baseName.prefix(12)))
                    }
                    monoName = AkaiDiskImage.disambiguateSampleName(monoName, usedNames: &usedNames)
                    let finalRate: UInt32
                    if loFi {
                        let (loPCM, loRate) = AkaiDiskImage.applyLoFi(pcm: monoData, fromRate: sampleRate)
                        monoData = loPCM; finalRate = loRate
                    } else { finalRate = UInt32(sampleRate) }
                    let sample = try diskImage.addImportedSample(
                        name: monoName, sampleRate: finalRate, numChannels: 1, pcmData: monoData)
                    let note = UInt8(min(nextNote, 127))
                    // Patch rkey to match pad key so TRACK plays at unity pitch.
                    var patched = sample
                    patched.header.midiRootNote = note
                    diskImage.applySampleEdits(patched)
                    newKeyzones.append(AkaiProgramKeyzone(
                        sampleName: sample.header.name,
                        lowKey: note, highKey: note, rootNote: 60,
                        tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                        filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                        filterResonance: 0, filterModDepth1: 0, filterModDepth2: 0, filterModDepth3: 0,
                        rightSampleName: "", rightPan: 50,
                        playbackMode: .sample, velocityLow: 0, velocityHigh: 127,
                        env1Attack: 0, env1Decay: 0, env1Sustain: 99, env1Release: 0, pitchMode: 0))
                    nextNote += 1
                } catch { break } // disk full
            }
            DispatchQueue.main.async {
                guard !newKeyzones.isEmpty else { return }
                commitProgramEdits()
            }
        }
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

// MARK: - Simple Drop Zone

/// A single, presentational drop target shown in the program's right panel when
/// no keyzone is selected. It does NOT handle the drop itself — the whole
/// ProgramDetailView already has an .onDrop that routes a dropped file to
/// dropFile (single sample → mapped across the keyboard) or a dropped folder to
/// dropFolder (each sample → its own key from C1, Const pitch). This view just
/// gives that view-wide drop a clear visual home and explains the two outcomes.
struct SimpleDropZone: View {
    /// Driven by the parent view's .onDrop isTargeted binding so the box lights
    /// up while dragging over anywhere in the program view.
    var isTargeted: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6]))
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop samples here")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Label("A single WAV maps across the whole keyboard.", systemImage: "pianokeys")
                    Label("A folder maps each WAV to its own key from C1.", systemImage: "square.grid.2x2")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 160)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
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
                    Text("Root: \(midiNoteName(keyzone.rootNote))").font(.caption).foregroundStyle(.blue)
                    if keyzone.lowKey == keyzone.highKey {
                        Text("Single: \(midiNoteName(keyzone.lowKey))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Range: \(midiNoteName(keyzone.lowKey))–\(midiNoteName(keyzone.highKey))").font(.caption).foregroundStyle(.secondary)
                    }
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 4)
                    }
                }
                InfoCard(title: "Tune") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Pitch Mode").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $keyzone.pitchMode) {
                                Text("Track").tag(UInt8(0))
                                Text("Const").tag(UInt8(1))
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: keyzone.pitchMode) { _, _ in onChange() }
                        }
                        Text(keyzone.pitchMode == 0
                             ? "Track: pitch follows the keyboard, transposing the sample normally across the key range — use for melodic/pitched instruments."
                             : "Const: always plays back as if C3 were pressed, regardless of which key triggers it — per the manual, this only matches the sample's true pitch if its root note is set to C3, which is why the recommended drum workflow is to sample everything at C3, then switch Const on.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 4)
                        HStack {
                            Text("Tune (st)").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Stepper("\(keyzone.tuneOffset)", value: $keyzone.tuneOffset, in: -24...24)
                                .onChange(of: keyzone.tuneOffset) { _, _ in onChange() }
                        }
                        HStack {
                            Text("Fine (¢)").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.fineTune) }, set: { keyzone.fineTune = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text("\(keyzone.fineTune)¢").frame(width: 35, alignment: .trailing).font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Volume").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.volume) }, set: { keyzone.volume = UInt8($0); onChange() }), in: 0...99, step: 1)
                            Text("\(keyzone.volume)").frame(width: 35, alignment: .trailing).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.pan) }, set: { keyzone.pan = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text(keyzone.pan == 0 ? "C" : keyzone.pan > 0 ? "R\(keyzone.pan)" : "L\(abs(keyzone.pan))")
                                .frame(width: 35, alignment: .trailing).font(.system(.caption, design: .monospaced))
                        }
                        if !keyzone.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Right Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                    Slider(value: .init(get: { Double(keyzone.rightPan) }, set: { keyzone.rightPan = Int8($0); onChange() }), in: -50...50, step: 1)
                                    Text(keyzone.rightPan == 0 ? "C" : keyzone.rightPan > 0 ? "R\(keyzone.rightPan)" : "L\(abs(keyzone.rightPan))")
                                        .frame(width: 35).font(.system(.caption, design: .monospaced))
                                }
                                Text("Pan for the stereo right channel (zone 2: \(keyzone.rightSampleName.trimmingCharacters(in: .whitespaces))). Real hardware convention is hard left/right (-50/+50).")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 4)
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
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                            } label: { Label("Reset to Akai Defaults", systemImage: "arrow.counterclockwise").font(.system(size: 11)) }
                            .buttonStyle(.bordered).controlSize(.small).tint(.blue)
                            .help("Reset ENV1 to hardware defaults: A=\(AkaiKeyzoneDefaults.env1Attack) D=\(AkaiKeyzoneDefaults.env1Decay) S=\(AkaiKeyzoneDefaults.env1Sustain) R=\(AkaiKeyzoneDefaults.env1Release)")
                            Spacer()
                        }
                    }
                }
                InfoCard(title: "Filter") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Frequency").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterCutoff) }, set: { keyzone.filterCutoff = UInt8($0); onChange() }), in: 0...99, step: 1)
                                Text("\(keyzone.filterCutoff)").frame(width: 30).font(.system(.body, design: .monospaced))
                            }
                            Text("Cutoff frequency of the 12dB/octave resonant lowpass filter. 99 = fully open (no filtering); lower values progressively remove high frequencies, darkening the tone.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Key Follow").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Stepper("\(keyzone.filterKeyFollow)", value: $keyzone.filterKeyFollow, in: -24...24)
                                    .onChange(of: keyzone.filterKeyFollow) { _, _ in onChange() }
                            }
                            Text("How much the cutoff tracks keyboard position. 0 = no tracking; +12 = filter opens one octave for every octave played up the keyboard.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Resonance").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterResonance) }, set: { keyzone.filterResonance = UInt8($0); onChange() }), in: 0...15, step: 1)
                                Text("\(keyzone.filterResonance)").frame(width: 30).font(.system(.body, design: .monospaced))
                            }
                            Text("Narrows the filter's response slope, emphasising harmonics around the cutoff frequency. High settings produce a resonant 'weeow' character.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(modSource1.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth1) }, set: { keyzone.filterModDepth1 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth1)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("\(modSource1.helpText) Range is ±50; the source itself is set once in Program Settings, shared by every keygroup.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(modSource2.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth2) }, set: { keyzone.filterModDepth2 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth2)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("\(modSource2.helpText) Range is ±50; the source itself is set once in Program Settings, shared by every keygroup.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(modSource3.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth3) }, set: { keyzone.filterModDepth3 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth3)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("\(modSource3.helpText) Range is ±50; the source itself is set once in Program Settings, shared by every keygroup.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Filter Trim").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterOffset) }, set: { keyzone.filterOffset = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterOffset)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("Small ±50 adjustment on top of Cutoff, for matching tone between adjacent keygroups.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2).padding(.bottom, 4)
                        }
                    }
                }
                InfoCard(title: "ENV2 — Shaping The Filter") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Controls how the filter cutoff changes over time. ENV2 is a 4-stage Rate/Level envelope: R1→L1, R2→L2, R3→L3 (sustain), R4→L4. Works with the filter mod depth above. (Manual p.107)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                            } label: { Label("Reset to Akai Defaults", systemImage: "arrow.counterclockwise").font(.system(size: 11)) }
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
    @State private var showingImport = false
    @State private var dropError: String? = nil
    @State private var showDropError = false
    @AppStorage("lowQualityImport") private var lowQualityImport = false
    private let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pianokeys")
                    .font(.title)
                    .foregroundStyle(.purple)
                Text("Programs").font(.title.bold())
                Spacer()
                Text("\(diskImage.programs.count) files").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if diskImage.programs.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView("No Programs", systemImage: "pianokeys",
                        description: Text("Right-click Programs in the sidebar to create one, or drag a WAV file onto this panel to create a preset from a single sample, or drag a folder to map each file to its own key."))
                    Button {
                        showingImport = true
                    } label: {
                        Label("Browse for Samples", systemImage: "square.and.arrow.down")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fileImporter(isPresented: $showingImport,
                              allowedContentTypes: [.audio],
                              allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    importFileAsPreset(url: url)
                }
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .alert("Import error", isPresented: $showDropError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropError ?? "")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            DispatchQueue.main.async {
                if isDir.boolValue {
                    importFolderAsDrumPreset(folderURL: url)
                } else if audioExts.contains(url.pathExtension.lowercased()) {
                    importFileAsPreset(url: url)
                } else {
                    dropError = "\(url.lastPathComponent) is not a supported audio file."
                    showDropError = true
                }
            }
        }
        return true
    }

    private func importFileAsPreset(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        guard let wavData = try? Data(contentsOf: url) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        if accessing { url.stopAccessingSecurityScopedResource() }
        let decoded: WAVImport.Decoded
        do { decoded = try WAVImport.decode(wavData) }
        catch {
            dropError = "\(url.lastPathComponent): \(error.localizedDescription)"
            showDropError = true
            return
        }
        let pcmData = decoded.pcm
        let sampleRate = decoded.sampleRate
        let numChannels = decoded.channels
        let rawName = url.deletingPathExtension().lastPathComponent
        let programName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))
        let loFi = lowQualityImport
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var monoData: Data; let monoName: String
                if numChannels >= 2 {
                    let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                    monoData = left
                    monoName = AkaiDiskImage.sanitizeNamePreservingEnd(rawName, maxLen: 10) + "-L"
                } else {
                    monoData = pcmData
                    monoName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))
                }
                let finalRate: UInt32
                if loFi {
                    let (loPCM, loRate) = AkaiDiskImage.applyLoFi(pcm: monoData, fromRate: sampleRate)
                    monoData = loPCM; finalRate = loRate
                } else { finalRate = UInt32(sampleRate) }
                let sample = try diskImage.addImportedSample(
                    name: monoName, sampleRate: finalRate,
                    numChannels: 1, pcmData: monoData)
                let prog = try diskImage.createProgram(name: programName)
                let kz = AkaiProgramKeyzone(
                    sampleName: sample.header.name,
                    lowKey: 24, highKey: UInt8(PianoKeyboardView.visibleEndNote), rootNote: 60,
                    tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                    filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                    filterResonance: 0, filterModDepth1: 0,
                    filterModDepth2: 0, filterModDepth3: 0,
                    rightSampleName: "", rightPan: 50,
                    playbackMode: .sample, velocityLow: 0, velocityHigh: 127)
                DispatchQueue.main.async {
                    var updated = diskImage.programs.first(where: { $0.id == prog.id }) ?? prog
                    updated.program.keyzones = [kz]
                    diskImage.applyProgramEdits(updated)
                    diskImage.hasUnsavedChanges = true
                    selectedProgramID = prog.id
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    showDropError = true
                }
            }
        }
    }

    private func importFolderAsDrumPreset(folderURL: URL) {
        let rawName = folderURL.lastPathComponent
        let programName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let audioURLs = contents
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !audioURLs.isEmpty else {
            dropError = "No audio files found in \"\(folderURL.lastPathComponent)\"."
            showDropError = true
            return
        }
        let prog: AkaiProgramFile
        do { prog = try diskImage.createProgram(name: programName) }
        catch {
            dropError = error.localizedDescription
            showDropError = true
            return
        }
        let loFi = lowQualityImport
        var usedNames = Set(diskImage.samples.map { $0.header.name })
        DispatchQueue.global(qos: .userInitiated).async {
            var keyzones: [AkaiProgramKeyzone] = []
            var nextNote = 36
            var hitLimit = false; var limitMsg = ""
            for url in audioURLs {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard let wavData = try? Data(contentsOf: url),
                          let decoded = try? WAVImport.decode(wavData) else { continue }
                    let pcmData = decoded.pcm
                    let sampleRate = decoded.sampleRate
                    let numChannels = decoded.channels
                    let baseName = url.deletingPathExtension().lastPathComponent
                    var monoData: Data; var monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left
                        monoName = AkaiDiskImage.sanitizeNamePreservingEnd(baseName, maxLen: 10) + "-L"
                    } else {
                        monoData = pcmData
                        monoName = AkaiDiskImage.sanitizeName(String(baseName.prefix(12)))
                    }
                    monoName = AkaiDiskImage.disambiguateSampleName(monoName, usedNames: &usedNames)
                    let finalRate: UInt32
                    if loFi {
                        let (loPCM, loRate) = AkaiDiskImage.applyLoFi(pcm: monoData, fromRate: sampleRate)
                        monoData = loPCM; finalRate = loRate
                    } else { finalRate = UInt32(sampleRate) }
                    let sample = try diskImage.addImportedSample(
                        name: monoName, sampleRate: finalRate,
                        numChannels: 1, pcmData: monoData)
                    let note = UInt8(min(nextNote, 127))
                    var patched = sample; patched.header.midiRootNote = note
                    diskImage.applySampleEdits(patched)
                    keyzones.append(AkaiProgramKeyzone(
                        sampleName: sample.header.name,
                        lowKey: note, highKey: note, rootNote: 60,
                        tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                        filterOffset: 0, filterCutoff: 99, filterKeyFollow: 0,
                        filterResonance: 0, filterModDepth1: 0,
                        filterModDepth2: 0, filterModDepth3: 0,
                        rightSampleName: "", rightPan: 50,
                        playbackMode: .sample, velocityLow: 0, velocityHigh: 127,
                        env1Attack: 0, env1Decay: 0, env1Sustain: 99, env1Release: 0, pitchMode: 0))
                    nextNote += 1
                } catch {
                    hitLimit = true
                    limitMsg = "Disk full — only \(keyzones.count) of \(audioURLs.count) samples imported."
                    break
                }
            }
            DispatchQueue.main.async {
                if !keyzones.isEmpty {
                    var updated = diskImage.programs.first(where: { $0.id == prog.id }) ?? prog
                    updated.program.keyzones = keyzones
                    diskImage.applyProgramEdits(updated)
                    diskImage.hasUnsavedChanges = true
                }
                if hitLimit { dropError = limitMsg; showDropError = true }
            }
        }
    }
}
