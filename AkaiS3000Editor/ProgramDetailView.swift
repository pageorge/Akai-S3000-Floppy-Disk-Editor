import SwiftUI

struct ProgramDetailView: View {
    let programFile: AkaiProgramFile
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var editedProgram: AkaiProgram
    @State private var selectedKeyzoneIndices: Set<Int> = []
    /// The most recently clicked keyzone — used as (a) the shift-click range
    /// anchor and (b) the "primary" keyzone whose values are shown in the piano
    /// keyboard / Low-Root-High pickers / editor when several are selected.
    @State private var anchorKeyzoneIndex: Int? = nil
    @State private var isDirty = false
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var toast: ToastData?
    @State private var showDeleteKeyzoneConfirm = false
    @State private var keyzoneKeyMonitor: Any? = nil
    /// True while the keyzone List has keyboard focus. Gates the key monitor
    /// below, mirroring SidebarView's `sidebarFocused` — without this gate, the
    /// monitor would fire (or fail to fire reliably) regardless of which list
    /// actually has focus, since two separate global key monitors are alive at
    /// once (this one and SidebarView's) whenever a program is open.
    @FocusState private var keyzoneListFocused: Bool
    @FocusState private var nameFieldFocused: Bool
    init(programFile: AkaiProgramFile, diskImage: AkaiDiskImage) {
        self.programFile = programFile
        self.diskImage = diskImage
        _editedProgram = State(initialValue: programFile.program)
    }

    /// Current display name, preferring the live disk-image copy (so a rename
    /// elsewhere is reflected) and falling back to the directory entry.
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
                            .help("Rename program")
                        }
                    }
                    Text("Program · \(editedProgram.keyzones.count) keyzones")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                            Stepper("\(editedProgram.polyphony)", value: $editedProgram.polyphony, in: 1...16)
                                .onChange(of: editedProgram.polyphony) { _, _ in commitProgramEdits() }
                        }
                        .help("Maximum simultaneous voices for this program (1–16).")
                        HStack {
                            Text("Bend Range").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Stepper("\(editedProgram.bendRange) semitones", value: $editedProgram.bendRange, in: 0...24)
                                .onChange(of: editedProgram.bendRange) { _, _ in commitProgramEdits() }
                        }
                        .help("Pitchbend wheel/lever range, 0–24 semitones. Default is 2. The S3000XL supports separate up/down ranges — this app sets both to the same value.")
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
                        Text("Filter modulation inputs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
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
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: .infinity)
                    .focused($keyzoneListFocused)
                    .onAppear {
                        keyzoneKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            // Only act when THIS list actually has keyboard focus
                            // (mirrors SidebarView's sidebarFocused gate) — without
                            // this, two independently-registered global key monitors
                            // (this one and SidebarView's) are both alive whenever a
                            // program is open, and arrow/delete handling becomes
                            // unreliable regardless of which list the user actually
                            // clicked into.
                            guard self.keyzoneListFocused, !diskImage.isEditingText else { return event }
                            if event.keyCode == 53 { // esc
                                if !self.selectedKeyzoneIndices.isEmpty {
                                    self.selectedKeyzoneIndices = []
                                    self.anchorKeyzoneIndex = nil
                                    return nil
                                }
                            }
                            if event.keyCode == 126 {        // up arrow
                                moveKeyzoneSelection(by: -1)
                                return nil
                            }
                            if event.keyCode == 125 {        // down arrow
                                moveKeyzoneSelection(by: 1)
                                return nil
                            }
                            if event.keyCode == 51 || event.keyCode == 117 {  // delete / forward-delete
                                if !selectedKeyzoneIndices.isEmpty {
                                    showDeleteKeyzoneConfirm = true
                                    return nil
                                }
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
                    // Sample pills — only shown when a keyzone is selected
                    if anchorKeyzoneIndex != nil && !diskImage.samples.isEmpty {
                        GroupBox("Sample (Zone 1, Left)") {
                            FlowLayout(spacing: 6) {
                                ForEach(diskImage.samples) { sample in
                                    samplePill(for: sample)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        GroupBox("Stereo Right Channel (Zone 2, optional)") {
                            VStack(alignment: .leading, spacing: 6) {
                                FlowLayout(spacing: 6) {
                                    ForEach(diskImage.samples) { sample in
                                        rightSamplePill(for: sample)
                                    }
                                }
                                Text("Pairs a second sample as the stereo right channel of this same keygroup — the real S3000 convention for stereo playback (one keygroup, two zones panned hard left/right), not two separate keygroups.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }

                    // Only show piano when there are keyzones
                    if !editedProgram.keyzones.isEmpty {
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

                        // Low / Root / High pickers positioned directly under the
                        // keyboard, matching their on-keyboard position: low at the
                        // bottom-left, root centred, high at the bottom-right.
                        if let idx = anchorKeyzoneIndex, idx < editedProgram.keyzones.count {
                            HStack {
                                MidiKeyPicker(label: "Low", value: keyzoneFieldBinding(idx, \.lowKey),
                                             onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "Root", value: keyzoneFieldBinding(idx, \.rootNote),
                                             onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "High", value: keyzoneFieldBinding(idx, \.highKey),
                                             onChange: { commitProgramEdits() })
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Create Preset")
                                .font(.headline)
                            Text(editedProgram.keyzones.isEmpty
                                ? "Add a keyzone to map existing samples (normal preset)"
                                : "Select a keyzone to edit")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()

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
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                    }

                    Spacer()
                }
            }
        }
        .onChange(of: isDirty) { _, dirty in
            // Only ever RAISE the global flag here, never lower it — see the
            // identical comment in SampleDetailView for why.
            if dirty { diskImage.hasUnsavedChanges = true }
        }
        .confirmationDialog(
            selectedKeyzoneIndices.count > 1
                ? "Delete \(selectedKeyzoneIndices.count) keyzones?"
                : "Delete this keyzone?",
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
            try diskImage.renameProgram(id: programFile.id, to: clean)
            editedProgram.name = clean
            isEditingName = false
            nameFieldFocused = false
            diskImage.isEditingText = false
            toast = ToastData(message: "Renamed to \(clean)")
        } catch {
            toast = ToastData(message: error.localizedDescription, isError: true)
        }
    }

    private func addKeyzone() {
        let newKZ = AkaiProgramKeyzone(
            sampleName: diskImage.samples.first?.header.name ?? "NO NAME",
            lowKey: 24, highKey: 127, rootNote: 60,
            tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
            filterOffset: 0,
            // 99 = filter wide open (no audible filtering) — matches real
            // hardware default and is a safe "inaudible until you touch it" start.
            filterCutoff: 99,
            // 0 matches the real factory/blank-keygroup default — confirmed by
            // photographing a fresh keygroup on a copy of TEST PROGRAM. The
            // manual's "+12 is the default" claim is its recommended starting
            // point for tonal playing, not what a never-touched keygroup contains.
            filterKeyFollow: 0,
            filterResonance: 0,
            filterModDepth1: 0,
            filterModDepth2: 0,
            filterModDepth3: 0,
            rightSampleName: "",
            rightPan: 50,
            // .sample mimics real S3000 hardware: a freshly created keygroup
            // defaults to "use the sample's own loop setting" (pmode 0x00, which
            // is also the natural zero-value default), not an override that
            // forces no loop. Previously this was `loopEnabled: false`, which
            // mapped to pmode 0x03 (NOLOOP) — silently overriding any loop the
            // user had carefully set up in Sample Edit.
            playbackMode: .sample, velocityLow: 0, velocityHigh: 127
        )
        editedProgram.keyzones.append(newKZ)
        let newIdx = editedProgram.keyzones.count - 1
        selectedKeyzoneIndices = [newIdx]
        anchorKeyzoneIndex = newIdx
        commitProgramEdits()
    }

    /// Duplicate the keyzone at `index` (all its settings) and insert the copy
    /// right after it, then select the new one (and only the new one) — mirrors
    /// cloneSample/cloneProgram.
    private func cloneKeyzone(at index: Int) {
        guard editedProgram.keyzones.indices.contains(index) else { return }
        let copy = editedProgram.keyzones[index]
        let insertAt = index + 1
        editedProgram.keyzones.insert(copy, at: insertAt)
        selectedKeyzoneIndices = [insertAt]
        anchorKeyzoneIndex = insertAt
        commitProgramEdits()
    }

    /// Remove every currently-selected keyzone and select a sensible neighbour
    /// afterwards. Replaces the old single-index deleteKeyzone(at:).
    private func deleteSelectedKeyzones() {
        guard !selectedKeyzoneIndices.isEmpty else { return }
        let sortedIndices = selectedKeyzoneIndices.sorted()
        let firstRemoved = sortedIndices.first ?? 0
        // Remove highest-index-first so earlier removals don't shift the
        // positions of indices still queued for removal.
        for idx in sortedIndices.reversed() where editedProgram.keyzones.indices.contains(idx) {
            editedProgram.keyzones.remove(at: idx)
        }
        if editedProgram.keyzones.isEmpty {
            selectedKeyzoneIndices = []
            anchorKeyzoneIndex = nil
        } else {
            let newIdx = min(firstRemoved, editedProgram.keyzones.count - 1)
            selectedKeyzoneIndices = [newIdx]
            anchorKeyzoneIndex = newIdx
        }
        commitProgramEdits()
    }

    /// Handle a click on keyzone row `idx`, replicating standard Finder/Mail-style
    /// multi-select: plain click selects just this row (or deselects if it was the
    /// only thing selected), ⌘-click toggles this row in/out of the selection,
    /// ⇧-click selects the contiguous range from the anchor to this row.
    private func handleKeyzoneTap(_ idx: Int, shift: Bool, command: Bool) {
        if shift, let anchor = anchorKeyzoneIndex {
            let range = anchor <= idx ? anchor...idx : idx...anchor
            selectedKeyzoneIndices = Set(range)
            // Anchor deliberately NOT moved on shift-click, so repeated shift-clicks
            // keep extending/shrinking the range from the same fixed start point.
        } else if command {
            if selectedKeyzoneIndices.contains(idx) {
                selectedKeyzoneIndices.remove(idx)
            } else {
                selectedKeyzoneIndices.insert(idx)
            }
            anchorKeyzoneIndex = idx
        } else {
            if selectedKeyzoneIndices == [idx] {
                selectedKeyzoneIndices = []
                anchorKeyzoneIndex = nil
            } else {
                selectedKeyzoneIndices = [idx]
                anchorKeyzoneIndex = idx
            }
        }
    }

    /// Move the keyzone selection up/down by `delta`, mirroring SidebarView's
    /// moveSelection — if nothing is selected yet, arrow keys select an end.
    /// Arrow-key navigation always collapses to a single selection (matching
    /// standard list behavior), even if several keyzones were selected before.
    private func moveKeyzoneSelection(by delta: Int) {
        let count = editedProgram.keyzones.count
        guard count > 0 else { return }
        let newIdx: Int
        if let idx = anchorKeyzoneIndex {
            newIdx = max(0, min(count - 1, idx + delta))
        } else {
            newIdx = delta > 0 ? 0 : count - 1
        }
        selectedKeyzoneIndices = [newIdx]
        anchorKeyzoneIndex = newIdx
    }

    /// Apply a field-level change made to the keyzone at `primaryIndex` to every
    /// OTHER currently-selected keyzone too — this is the actual "highlight
    /// several, change a setting, it updates all of them" feature, mirroring the
    /// real S3000XL's ED: ALL mode. Works by diffing `newValue` against the
    /// primary's CURRENT value and copying over only the field(s) that actually
    /// changed (in practice, exactly one per UI interaction — one slider/stepper/
    /// picker edits one property at a time), so unrelated fields on the other
    /// selected keyzones are left untouched.
    ///
    /// `sampleName` is deliberately EXCLUDED from the broadcast, matching the
    /// real hardware's own documented behavior (S3000XL manual, SMP1 page note):
    /// "Selecting ALL doesn't apply to assigning samples... only one sample is
    /// assigned and the other keygroups remain unchanged even if ALL is
    /// selected." Every other field (key range, root note, velocity range, tune,
    /// volume, pan, filter, playback mode) IS broadcast.
    private func applyToSelectedKeyzones(_ newValue: AkaiProgramKeyzone, primaryIndex: Int) {
        guard editedProgram.keyzones.indices.contains(primaryIndex) else { return }
        let old = editedProgram.keyzones[primaryIndex]
        editedProgram.keyzones[primaryIndex] = newValue

        let others = selectedKeyzoneIndices.subtracting([primaryIndex])
            .filter { editedProgram.keyzones.indices.contains($0) }
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
            // sampleName / rightSampleName / rightPan: intentionally not copied
            // — see doc comment above. A stereo pairing is specific to one
            // keygroup's two samples; broadcasting it to other selected
            // keygroups would assign the wrong right-channel sample to them.
            editedProgram.keyzones[idx] = kz
        }
    }

    /// A binding to a single UInt8 field (lowKey/highKey/rootNote) on the keyzone
    /// at `idx`, routed through applyToSelectedKeyzones so the MIDI key pickers
    /// broadcast to the rest of the selection exactly like every other control.
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

    /// Push the current `editedProgram` into the in-memory disk image so the
    /// global Save (or quit-confirmation) picks it up — mirrors
    /// SampleDetailView's commitEditsToImage. Does not write a file.
    ///
    /// IMPORTANT: must start from the LIVE entry in diskImage.programs, not the
    /// `programFile` constant captured at init. `programFile` never updates, but
    /// applyProgramEdits reallocates the program to new FAT blocks (and updates
    /// its `.offset`/`.directoryEntry`) whenever the keygroup count changes the
    /// file's size. If we kept reusing the stale `programFile.offset` here, every
    /// edit AFTER the first resize would operate on the WRONG (already-freed or
    /// reused) block chain — either silently corrupting unrelated data or hitting
    /// applyProgramEdits' "not enough room, leave disk untouched" bailout, which
    /// discards the edit entirely. That's exactly what "keyzones no longer saving"
    /// looked like: the first add/remove-keyzone edit in a session would persist,
    /// every edit after it silently wouldn't.
    private func commitProgramEdits() {
        isDirty = true
        var updated = diskImage.programs.first(where: { $0.id == programFile.id }) ?? programFile
        updated.program = editedProgram
        diskImage.applyProgramEdits(updated)
    }

    /// Toggle whether `name` is assigned to the currently selected keyzone.
    /// Tapping the already-assigned sample's pill clears the assignment;
    /// tapping any other pill assigns it (replacing whatever was there) —
    /// this is the whole "sample picker", replacing the old dropdown.
    ///
    /// Always applies to the ANCHOR keyzone only, even when several are
    /// selected — matching the real S3000XL's documented behavior that ALL mode
    /// never broadcasts sample assignment (see applyToSelectedKeyzones' doc
    /// comment for the manual quote).
    private func toggleSample(_ name: String) {
        guard let idx = anchorKeyzoneIndex, editedProgram.keyzones.indices.contains(idx) else { return }
        if editedProgram.keyzones[idx].sampleName == name {
            editedProgram.keyzones[idx].sampleName = ""
        } else {
            editedProgram.keyzones[idx].sampleName = name
        }
        commitProgramEdits()
    }

    /// Toggle whether `name` is assigned as the STEREO RIGHT channel (zone 2)
    /// of the currently selected keyzone — the real hardware convention for
    /// stereo playback: one keygroup, left sample in zone 1, right sample in
    /// zone 2, each panned hard left/right (see AkaiProgramKeyzone.rightSampleName
    /// doc comment for the manual citation). Tapping the already-assigned right
    /// sample's pill clears the stereo pairing entirely (reverting to mono);
    /// tapping any other pill assigns it.
    ///
    /// The first time a right sample is assigned to a keyzone that's still at
    /// pan=0 (center, i.e. never deliberately panned), this also nudges zone 1
    /// to hard left (−50) to match — the real hardware default for a stereo
    /// pair — without overriding a pan the user already set on purpose.
    ///
    /// Symmetrically, clearing the stereo pairing (un-assigning zone 2) resets
    /// zone 1's pan back to center (0) — but ONLY if pan is still exactly −50,
    /// i.e. it still looks like the value this same nudge set and the user
    /// hasn't deliberately repanned zone 1 since. If they have, their pan choice
    /// is left alone.
    private func toggleRightSample(_ name: String) {
        guard let idx = anchorKeyzoneIndex, editedProgram.keyzones.indices.contains(idx) else { return }
        if editedProgram.keyzones[idx].rightSampleName == name {
            editedProgram.keyzones[idx].rightSampleName = ""
            if editedProgram.keyzones[idx].pan == -50 {
                editedProgram.keyzones[idx].pan = 0
            }
        } else {
            editedProgram.keyzones[idx].rightSampleName = name
            editedProgram.keyzones[idx].rightPan = 50
            if editedProgram.keyzones[idx].pan == 0 {
                editedProgram.keyzones[idx].pan = -50
            }
        }
        commitProgramEdits()
    }

    /// One sample pill: filled red when it's the selected keyzone's assigned
    /// sample, outlined otherwise. Dimmed (and inert) when no keyzone is selected,
    /// since there's nothing yet to assign it to.
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isAssigned ? Color.red : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isAssigned ? Color.clear : Color.secondary.opacity(0.35)))
            .opacity(hasSelection ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture { if hasSelection { toggleSample(name) } }
            .help(hasSelection ? (isAssigned ? "Remove from this keyzone" : "Assign to this keyzone")
                                : "Select a keyzone first")
    }

    /// One "right channel" pill, for assigning a stereo pair's RIGHT sample to
    /// zone 2 of the selected keyzone (see toggleRightSample). Filled blue when
    /// it's the assigned right channel — a different color from the regular
    /// (red) sample pills so the two rows are never visually confused, since a
    /// sample could in principle be tapped into either row.
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isAssigned ? Color.blue : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isAssigned ? Color.clear : Color.secondary.opacity(0.35)))
            .opacity(hasSelection ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture { if hasSelection { toggleRightSample(name) } }
            .help(hasSelection ? (isAssigned ? "Remove stereo right channel" : "Assign as stereo right channel (zone 2)")
                                : "Select a keyzone first")
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

    /// Next available MIDI note, starting at C1 (24), offset by existing keyzone count.
    private var nextMidiNote: Int {
        24 + diskImage.programs.flatMap { $0.program.keyzones }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create Drum Preset")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDragging ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDragging ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [6])
                    )
                VStack(spacing: 6) {
                    if isImporting {
                        ProgressView("Importing samples...")
                            .padding()
                    } else {
                        Button {
                            openSamples()
                        } label: {
                            Label("Browse for Drum Samples", systemImage: "square.and.arrow.down.on.square")
                                .frame(width: 200)
                                .padding(.vertical, 10)
                                .foregroundStyle(.white)
                                .background(akaiRed)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        Text("or drag .wav files here")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
            }
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
                return true
            }

            // Info note
            VStack(alignment: .leading, spacing: 3) {
                Label("Samples will be mapped to individual keys from C1 upwards.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Label("For stereo samples, only the left channel will be imported.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func openSamples() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Choose samples for drum preset"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      audioExts.contains(url.pathExtension.lowercased()) else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) {
            importURLs(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        errorMessage = nil
        var newKeyzones: [AkaiProgramKeyzone] = []
        var nextNote: Int
        if let lastNote = existingKeyzones.last.map({ Int($0.rootNote) }) {
            nextNote = lastNote + 1
        } else {
            nextNote = 24
        }
        var errors: [String] = []

        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                do {
                    let wavData = try Data(contentsOf: url)
                    // Parse the WAV to check channel count.
                    let (pcmData, sampleRate, numChannels, _) = try parseWAV(wavData)
                    let baseName = AkaiDiskImage.sanitizeName(
                        url.deletingPathExtension().lastPathComponent)

                    // Left channel only for stereo; mono passes straight through.
                    let monoData: Data
                    let monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left
                        monoName = String(baseName.prefix(10)) + "-L"
                    } else {
                        monoData = pcmData
                        monoName = baseName
                    }

                    let sample = try diskImage.addImportedSample(
                        name: monoName,
                        sampleRate: UInt32(sampleRate),
                        numChannels: 1,
                        pcmData: monoData)

                    // Map to a single key: low = high = root = nextNote.
                    let note = UInt8(min(nextNote, 127))
                    newKeyzones.append(AkaiProgramKeyzone(
                        sampleName: sample.header.name,
                        lowKey: note, highKey: note, rootNote: note,
                        tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
                        filterOffset: 0,
                        filterCutoff: 99,
                        filterKeyFollow: 0,
                        filterResonance: 0,
                        filterModDepth1: 0,
                        filterModDepth2: 0,
                        filterModDepth3: 0,
                        rightSampleName: "",
                        rightPan: 50,
                        // .noLoop, NOT .sample: drum/percussion hits are one-shots
                        // by nature — force no loop regardless of whatever loop
                        // points happen to be set on the sample itself. Unlike
                        // addKeyzone() (regular keyzones, which mimic the hardware
                        // default of inheriting the sample's setting), a drum
                        // preset should never loop just because the source WAV/
                        // sample had a loop region.
                        playbackMode: .noLoop, velocityLow: 0, velocityHigh: 127))
                    nextNote += 1
                } catch {
                    errors.append(url.lastPathComponent + ": " + error.localizedDescription)
                }
            }

            DispatchQueue.main.async {
                isImporting = false
                if !newKeyzones.isEmpty { onSamplesImported(newKeyzones) }
                if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
            }
        }
    }

    /// Minimal WAV parser — mirrors AkaiDiskImage.parseWAV which is private.
    private func parseWAV(_ data: Data) throws -> (Data, Int, Int, Int) {
        guard data.count > 44,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else {
            throw NSError(domain: "WAV", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Not a valid WAV file"])
        }
        var offset = 12, sampleRate = 44100, numChannels = 1, bitsPerSample = 16
        var pcmData = Data()
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(data.readLE32(at: offset + 4))
            offset += 8
            if id == "fmt " {
                numChannels   = Int(data.readLE16(at: offset + 2))
                sampleRate    = Int(data.readLE32(at: offset + 4))
                bitsPerSample = Int(data.readLE16(at: offset + 14))
            } else if id == "data" {
                pcmData = data.subdata(in: offset..<min(offset + size, data.count))
            }
            offset += size + (size % 2)
        }
        guard !pcmData.isEmpty else {
            throw NSError(domain: "WAV", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio data in WAV"])
        }
        return (pcmData, sampleRate, numChannels, bitsPerSample)
    }
}

// MARK: - Keyzone Row

struct KeyzoneRow: View {
    let keyzone: AkaiProgramKeyzone
    let sampleNames: [String]

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue.opacity(0.7))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : keyzone.sampleName)
                        .font(.system(.body, design: .monospaced)).lineLimit(1)
                    if !keyzone.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("L+R")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.2)))
                            .foregroundStyle(.blue)
                            .help("Stereo pair: zone 2 = \(keyzone.rightSampleName.trimmingCharacters(in: .whitespaces))")
                    }
                }
                HStack(spacing: 8) {
                    Text("\(midiNoteName(keyzone.lowKey))–\(midiNoteName(keyzone.highKey))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Root: \(midiNoteName(keyzone.rootNote))")
                        .font(.caption).foregroundStyle(.blue)
                    Text("Vel: \(keyzone.velocityLow)–\(keyzone.velocityHigh)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        // -2, not -1: matches the real S3000XL's own octave display (confirmed
        // against hardware), not the common "middle C = C4" MIDI convention.
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
    }
}

// MARK: - Keyzone Editor

struct KeyzoneEditorView: View {
    @Binding var keyzone: AkaiProgramKeyzone
    var selectedCount: Int = 1
    /// Program-level mod sources (read-only here — see AkaiProgram.filterModSource1/2/3's
    /// doc comment for why these aren't per-keyzone). Edited in Program Settings, not here.
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
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }

                InfoCard(title: "Playback") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Playback Mode").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Picker("", selection: $keyzone.playbackMode) {
                                ForEach(AkaiPlaybackMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: keyzone.playbackMode) { _, _ in onChange() }
                            Spacer()
                        }
                        Text(keyzone.playbackMode.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                            .padding(.leading, 100)
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
                            Slider(value: .init(get: { Double(keyzone.fineTune) },
                                               set: { keyzone.fineTune = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text("\(keyzone.fineTune)¢").frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Volume").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.volume) },
                                               set: { keyzone.volume = UInt8($0); onChange() }), in: 0...99, step: 1)
                            Text("\(keyzone.volume)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.pan) },
                                               set: { keyzone.pan = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text(keyzone.pan == 0 ? "C" : keyzone.pan > 0 ? "R\(keyzone.pan)" : "L\(abs(keyzone.pan))")
                                .frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        if !keyzone.rightSampleName.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Right Pan").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                    Slider(value: .init(get: { Double(keyzone.rightPan) },
                                                       set: { keyzone.rightPan = Int8($0); onChange() }), in: -50...50, step: 1)
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
                            Slider(value: .init(get: { Double(keyzone.velocityLow) },
                                               set: { keyzone.velocityLow = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityLow)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("High Velocity").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: .init(get: { Double(keyzone.velocityHigh) },
                                               set: { keyzone.velocityHigh = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityHigh)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                    }
                }

                InfoCard(title: "ENV1 — Shaping Amplitude") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Controls the volume shape of each note over time. Attack sets how quickly the sound reaches full volume; Decay how quickly it falls to the Sustain level; Sustain the held level while the key is held; Release how quickly it fades after key release. (Manual p.105)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                keyzone.env1Attack = AkaiKeyzoneDefaults.env1Attack
                                keyzone.env1Decay = AkaiKeyzoneDefaults.env1Decay
                                keyzone.env1Sustain = AkaiKeyzoneDefaults.env1Sustain
                                keyzone.env1Release = AkaiKeyzoneDefaults.env1Release
                                onChange()
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                            .help("Reset ENV1 to hardware defaults: A=\(AkaiKeyzoneDefaults.env1Attack) D=\(AkaiKeyzoneDefaults.env1Decay) S=\(AkaiKeyzoneDefaults.env1Sustain) R=\(AkaiKeyzoneDefaults.env1Release)")
                            Spacer()
                        }
                        .zIndex(1)
                        HStack(alignment: .center, spacing: 12) {
                            AdsrView(
                                attack: Binding(get: { keyzone.env1Attack }, set: { keyzone.env1Attack = $0; onChange() }),
                                decay: Binding(get: { keyzone.env1Decay }, set: { keyzone.env1Decay = $0; onChange() }),
                                sustain: Binding(get: { keyzone.env1Sustain }, set: { keyzone.env1Sustain = $0; onChange() }),
                                release: Binding(get: { keyzone.env1Release }, set: { keyzone.env1Release = $0; onChange() })
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                EnvSlider(label: "Attack", value: Binding(get: { keyzone.env1Attack }, set: { keyzone.env1Attack = $0; onChange() }),
                                          caption: "How quickly the sound reaches full volume on note-on. 0 = instant, 99 = slow fade in.")
                                EnvSlider(label: "Decay", value: Binding(get: { keyzone.env1Decay }, set: { keyzone.env1Decay = $0; onChange() }),
                                          caption: "How quickly the volume falls from the attack peak to the Sustain level.")
                                EnvSlider(label: "Sustain", value: Binding(get: { keyzone.env1Sustain }, set: { keyzone.env1Sustain = $0; onChange() }),
                                          caption: "Volume level held while the key is down. 0 = silent, 99 = full level.")
                                EnvSlider(label: "Release", value: Binding(get: { keyzone.env1Release }, set: { keyzone.env1Release = $0; onChange() }),
                                          caption: "How quickly the sound fades after key release. 0 = instant cutoff, 99 = long fade.")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                InfoCard(title: "Filter") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Frequency").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterCutoff) },
                                                   set: { keyzone.filterCutoff = UInt8($0); onChange() }), in: 0...99, step: 1)
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
                                Slider(value: .init(get: { Double(keyzone.filterResonance) },
                                                   set: { keyzone.filterResonance = UInt8($0); onChange() }), in: 0...15, step: 1)
                                Text("\(keyzone.filterResonance)").frame(width: 30).font(.system(.body, design: .monospaced))
                            }
                            Text("Narrows the filter's response slope, emphasising harmonics around the cutoff frequency. High settings produce a resonant 'weeow' character. Watch for distortion at high settings — use the -6dB pad or reduce program output level if needed.")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource1.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth1) },
                                                   set: { keyzone.filterModDepth1 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth1)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source opens/closes the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource2.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth2) },
                                                   set: { keyzone.filterModDepth2 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth2)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source sweeps the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(modSource3.displayName).frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterModDepth3) },
                                                   set: { keyzone.filterModDepth3 = Int8($0); onChange() }), in: -50...50, step: 1)
                                Text("\(keyzone.filterModDepth3)").frame(width: 35).font(.system(.caption, design: .monospaced))
                            }
                            Text("How much this source shapes the filter (±50). Source is set in Program Settings (shared by every keygroup).")
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.leading, 100)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Filter Trim").frame(width: 100, alignment: .leading).font(.subheadline).foregroundStyle(.secondary)
                                Slider(value: .init(get: { Double(keyzone.filterOffset) },
                                                   set: { keyzone.filterOffset = Int8($0); onChange() }), in: -50...50, step: 1)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                keyzone.env2R1 = AkaiKeyzoneDefaults.env2R1
                                keyzone.env2L1 = AkaiKeyzoneDefaults.env2L1
                                keyzone.env2R2 = AkaiKeyzoneDefaults.env2R2
                                keyzone.env2L2 = AkaiKeyzoneDefaults.env2L2
                                keyzone.env2R3 = AkaiKeyzoneDefaults.env2R3
                                keyzone.env2L3 = AkaiKeyzoneDefaults.env2L3
                                keyzone.env2R4 = AkaiKeyzoneDefaults.env2R4
                                keyzone.env2L4 = AkaiKeyzoneDefaults.env2L4
                                onChange()
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                            .help("Reset ENV2 to hardware defaults: R1=\(AkaiKeyzoneDefaults.env2R1) L1=\(AkaiKeyzoneDefaults.env2L1) R2=\(AkaiKeyzoneDefaults.env2R2) L2=\(AkaiKeyzoneDefaults.env2L2) R3=\(AkaiKeyzoneDefaults.env2R3) L3=\(AkaiKeyzoneDefaults.env2L3) R4=\(AkaiKeyzoneDefaults.env2R4) L4=\(AkaiKeyzoneDefaults.env2L4)")
                            Spacer()
                        }
                        .zIndex(1)
                        HStack(alignment: .center, spacing: 12) {
                            AdsrView(
                                attack: Binding(get: { keyzone.env2R1 }, set: { keyzone.env2R1 = $0; onChange() }),
                                decay: Binding(get: { keyzone.env2R2 }, set: { keyzone.env2R2 = $0; onChange() }),
                                sustain: Binding(get: { keyzone.env2L3 }, set: { keyzone.env2L3 = $0; onChange() }),
                                release: Binding(get: { keyzone.env2R4 }, set: { keyzone.env2R4 = $0; onChange() }),
                                color: .orange
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                EnvSlider(label: "R1", value: Binding(get: { keyzone.env2R1 }, set: { keyzone.env2R1 = $0; onChange() }),
                                          caption: "Rate 1: how quickly the filter opens on note-on.")
                                EnvSlider(label: "L1", value: Binding(get: { keyzone.env2L1 }, set: { keyzone.env2L1 = $0; onChange() }),
                                          caption: "Level 1: the peak level reached after Rate 1.")
                                EnvSlider(label: "R2", value: Binding(get: { keyzone.env2R2 }, set: { keyzone.env2R2 = $0; onChange() }),
                                          caption: "Rate 2: how quickly it falls from L1 to L2.")
                                EnvSlider(label: "L2", value: Binding(get: { keyzone.env2L2 }, set: { keyzone.env2L2 = $0; onChange() }),
                                          caption: "Level 2: intermediate level.")
                                EnvSlider(label: "R3", value: Binding(get: { keyzone.env2R3 }, set: { keyzone.env2R3 = $0; onChange() }),
                                          caption: "Rate 3: how quickly it moves from L2 to L3.")
                                EnvSlider(label: "L3", value: Binding(get: { keyzone.env2L3 }, set: { keyzone.env2L3 = $0; onChange() }),
                                          caption: "Level 3: sustain level held while key is pressed.")
                                EnvSlider(label: "R4", value: Binding(get: { keyzone.env2R4 }, set: { keyzone.env2R4 = $0; onChange() }),
                                          caption: "Rate 4: how quickly the filter closes after key release.")
                                EnvSlider(label: "L4", value: Binding(get: { keyzone.env2L4 }, set: { keyzone.env2L4 = $0; onChange() }),
                                          caption: "Level 4: final level after release.")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Round Icon Button

/// A small circular icon button with a real, generous tappable area — unlike a
/// bare SF Symbol with `.buttonStyle(.borderless)`, whose hit target is just the
/// glyph's own tight bounding box. Used for the Keyzones list's +/- controls,
/// which were previously only clickable if you hit the glyph pixels exactly.
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
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
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
                // Reversed (127 → 0) so the dropdown lists highest-to-lowest, top
                // to bottom — matching the on-keyboard layout (high notes are to
                // the right/visually "up" in pitch) rather than the raw MIDI
                // note-number order.
                ForEach((0..<128).reversed(), id: \.self) { note in
                    Text(noteName(UInt8(note))).tag(UInt8(note))
                }
            }
            .labelsHidden()
            .onChange(of: value) { _, _ in onChange() }
        }
    }

    private func noteName(_ note: UInt8) -> String {
        // -2, not -1: matches the real S3000XL's own octave display (confirmed
        // against hardware: keylo=24 shows as "C_0", not "C1"), not the common
        // "middle C = C4" MIDI convention.
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
