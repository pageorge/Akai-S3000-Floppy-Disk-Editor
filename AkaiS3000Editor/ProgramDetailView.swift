import SwiftUI

struct ProgramDetailView: View {
    let programFile: AkaiProgramFile
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var editedProgram: AkaiProgram
    @State private var selectedKeyzoneIndex: Int? = nil
    @State private var isDirty = false
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var toast: ToastData?
    @State private var keyzoneKeyMonitor: Any? = nil
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var keyzoneListFocused: Bool

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
                if isDirty {
                    Button("Revert") {
                        editedProgram = programFile.program
                        isDirty = false
                        diskImage.applyProgramEdits(programFile)
                    }.buttonStyle(.bordered)
                }
            }
            .padding()

            Divider()

            HSplitView {
                // Left: program settings + keyzone list
                VStack(alignment: .leading, spacing: 0) {
                    GroupBox("Program Settings") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("MIDI Channel").frame(width: 100, alignment: .leading)
                                Picker("", selection: $editedProgram.midiChannel) {
                                    Text("Omni").tag(UInt8(0))
                                    ForEach(1..<17) { ch in Text("\(ch)").tag(UInt8(ch)) }
                                }
                                .labelsHidden()
                                .onChange(of: editedProgram.midiChannel) { _, _ in commitProgramEdits() }
                            }
                            HStack {
                                Text("Polyphony").frame(width: 100, alignment: .leading)
                                Stepper("\(editedProgram.polyphony)", value: $editedProgram.polyphony, in: 1...16)
                                    .onChange(of: editedProgram.polyphony) { _, _ in commitProgramEdits() }
                            }
                            HStack {
                                Text("Bend Range").frame(width: 100, alignment: .leading)
                                Stepper("\(editedProgram.bendRange) st", value: $editedProgram.bendRange, in: 0...12)
                                    .onChange(of: editedProgram.bendRange) { _, _ in commitProgramEdits() }
                            }
                        }
                    }
                    .padding()

                    Divider()

                    HStack {
                        Text("Keyzones").font(.headline)
                        Spacer()
                        Button { addKeyzone() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                        Button {
                            if let idx = selectedKeyzoneIndex { deleteKeyzone(at: idx) }
                        } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selectedKeyzoneIndex == nil)
                    }
                    .padding(.horizontal).padding(.top, 8)

                    List(selection: $selectedKeyzoneIndex) {
                        ForEach(Array(editedProgram.keyzones.enumerated()), id: \.offset) { idx, kz in
                            KeyzoneRow(keyzone: kz, sampleNames: diskImage.samples.map { $0.header.name })
                                .tag(idx)
                                .onTapGesture { selectedKeyzoneIndex = idx }
                                .contextMenu {
                                    Button { addKeyzone() } label: {
                                        Label("New Keyzone", systemImage: "plus.square.on.square")
                                    }
                                    Button { cloneKeyzone(at: idx) } label: {
                                        Label("Clone", systemImage: "plus.square.on.square")
                                    }
                                    Divider()
                                    Button(role: .destructive) { deleteKeyzone(at: idx) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.inset)
                    .focused($keyzoneListFocused)
                    .onAppear {
                        keyzoneKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            // Only act when this list actually has keyboard focus,
                            // so we never double-handle the same keypress alongside
                            // SidebarView's identical (always-active) key monitor.
                            guard keyzoneListFocused, !diskImage.isEditingText else { return event }
                            if event.keyCode == 126 {        // up arrow
                                moveKeyzoneSelection(by: -1)
                                return nil
                            }
                            if event.keyCode == 125 {        // down arrow
                                moveKeyzoneSelection(by: 1)
                                return nil
                            }
                            if event.keyCode == 51 || event.keyCode == 117 {  // delete / forward-delete
                                if let idx = selectedKeyzoneIndex {
                                    deleteKeyzone(at: idx)
                                    return nil
                                }
                            }
                            return event
                        }
                    }
                    .onDisappear {
                        if let m = keyzoneKeyMonitor { NSEvent.removeMonitor(m); keyzoneKeyMonitor = nil }
                    }
                }
                .frame(minWidth: 280, maxWidth: 360)

                // Right: sample picker + piano keyboard + keyzone editor
                VStack(alignment: .leading, spacing: 0) {
                    // Sample picker — pills above the keys, one tap assigns/removes
                    // the sample from whichever keyzone is currently selected.
                    GroupBox("Sample") {
                        if diskImage.samples.isEmpty {
                            Text("No samples on this disk")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(diskImage.samples) { sample in
                                    samplePill(for: sample)
                                }
                            }
                        }
                    }
                    .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

                    // Only show piano when there are keyzones
                    if !editedProgram.keyzones.isEmpty {
                        PianoKeyboardView(
                            keyzones: editedProgram.keyzones,
                            selectedIndex: selectedKeyzoneIndex,
                            onKeyzoneChanged: { updated in
                                if let idx = selectedKeyzoneIndex, idx < editedProgram.keyzones.count {
                                    editedProgram.keyzones[idx] = updated
                                    commitProgramEdits()
                                }
                            }
                        )
                        .frame(height: 140)
                        .background(Color(nsColor: .controlBackgroundColor))

                        // Low / Root / High pickers positioned directly under the
                        // keyboard, matching their on-keyboard position: low at the
                        // bottom-left, root centred, high at the bottom-right.
                        if let idx = selectedKeyzoneIndex, idx < editedProgram.keyzones.count {
                            HStack {
                                MidiKeyPicker(label: "Low", value: $editedProgram.keyzones[idx].lowKey,
                                             onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "Root", value: $editedProgram.keyzones[idx].rootNote,
                                             onChange: { commitProgramEdits() })
                                Spacer()
                                MidiKeyPicker(label: "High", value: $editedProgram.keyzones[idx].highKey,
                                             onChange: { commitProgramEdits() })
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }

                        Divider()
                    }

                    if let idx = selectedKeyzoneIndex, idx < editedProgram.keyzones.count {
                        KeyzoneEditorView(
                            keyzone: $editedProgram.keyzones[idx],
                            onChange: { commitProgramEdits() }
                        )
                        .padding()
                    } else {
                        // Compact placeholder — no big empty space
                        HStack {
                            Image(systemName: "pianokeys").foregroundStyle(.secondary)
                            Text(editedProgram.keyzones.isEmpty ? "Add a keyzone to get started" : "Select a keyzone to edit")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }

                    Spacer()
                }
            }
        }
        .onChange(of: isDirty) { _, _ in diskImage.hasUnsavedChanges = isDirty }
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
            lowKey: 0, highKey: UInt8(PianoKeyboardView.visibleEndNote), rootNote: 60,
            tuneOffset: 0, fineTune: 0, volume: 99, pan: 0,
            loopEnabled: false, velocityLow: 0, velocityHigh: 127
        )
        editedProgram.keyzones.append(newKZ)
        selectedKeyzoneIndex = editedProgram.keyzones.count - 1
        commitProgramEdits()
    }

    /// Duplicate the keyzone at `index` (all its settings) and insert the copy
    /// right after it, then select the new one — mirrors cloneSample/cloneProgram.
    private func cloneKeyzone(at index: Int) {
        guard editedProgram.keyzones.indices.contains(index) else { return }
        let copy = editedProgram.keyzones[index]
        let insertAt = index + 1
        editedProgram.keyzones.insert(copy, at: insertAt)
        selectedKeyzoneIndex = insertAt
        commitProgramEdits()
    }

    /// Remove the keyzone at `index` and select a sensible neighbour afterwards.
    private func deleteKeyzone(at index: Int) {
        guard editedProgram.keyzones.indices.contains(index) else { return }
        editedProgram.keyzones.remove(at: index)
        if editedProgram.keyzones.isEmpty {
            selectedKeyzoneIndex = nil
        } else {
            selectedKeyzoneIndex = min(index, editedProgram.keyzones.count - 1)
        }
        commitProgramEdits()
    }

    /// Move the keyzone selection up/down by `delta`, mirroring SidebarView's
    /// moveSelection — if nothing is selected yet, arrow keys select an end.
    private func moveKeyzoneSelection(by delta: Int) {
        let count = editedProgram.keyzones.count
        guard count > 0 else { return }
        if let idx = selectedKeyzoneIndex {
            selectedKeyzoneIndex = max(0, min(count - 1, idx + delta))
        } else {
            selectedKeyzoneIndex = delta > 0 ? 0 : count - 1
        }
    }

    /// Push the current `editedProgram` into the in-memory disk image so the
    /// global Save (or quit-confirmation) picks it up — mirrors
    /// SampleDetailView's commitEditsToImage. Does not write a file.
    private func commitProgramEdits() {
        isDirty = true
        var updated = programFile
        updated.program = editedProgram
        diskImage.applyProgramEdits(updated)
    }

    /// Toggle whether `name` is assigned to the currently selected keyzone.
    /// Tapping the already-assigned sample's pill clears the assignment;
    /// tapping any other pill assigns it (replacing whatever was there) —
    /// this is the whole "sample picker", replacing the old dropdown.
    private func toggleSample(_ name: String) {
        guard let idx = selectedKeyzoneIndex, editedProgram.keyzones.indices.contains(idx) else { return }
        if editedProgram.keyzones[idx].sampleName == name {
            editedProgram.keyzones[idx].sampleName = ""
        } else {
            editedProgram.keyzones[idx].sampleName = name
        }
        commitProgramEdits()
    }

    /// One sample pill: filled red when it's the selected keyzone's assigned
    /// sample, outlined otherwise. Dimmed (and inert) when no keyzone is selected,
    /// since there's nothing yet to assign it to.
    @ViewBuilder
    private func samplePill(for sample: AkaiSample) -> some View {
        let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
        let hasSelection = selectedKeyzoneIndex != nil
        let isAssigned = selectedKeyzoneIndex.flatMap { idx in
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
                Text(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : keyzone.sampleName)
                    .font(.system(.body, design: .monospaced)).lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(midiNoteName(keyzone.lowKey))–\(midiNoteName(keyzone.highKey))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Root: \(midiNoteName(keyzone.rootNote))")
                        .font(.caption).foregroundStyle(.blue)
                    Text("Vel: \(keyzone.velocityLow)–\(keyzone.velocityHigh)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}

// MARK: - Keyzone Editor

struct KeyzoneEditorView: View {
    @Binding var keyzone: AkaiProgramKeyzone
    let onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keyzone Settings").font(.headline)

                HStack(spacing: 6) {
                    Text("Sample:").font(.subheadline).foregroundStyle(.secondary)
                    Text(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "(none assigned — tap a pill above)" : keyzone.sampleName)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.red)
                }

                GroupBox("Velocity") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Low Velocity").frame(width: 100, alignment: .leading).font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.velocityLow) },
                                               set: { keyzone.velocityLow = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityLow)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("High Velocity").frame(width: 100, alignment: .leading).font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.velocityHigh) },
                                               set: { keyzone.velocityHigh = UInt8($0); onChange() }), in: 0...127, step: 1)
                            Text("\(keyzone.velocityHigh)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                    }
                }

                GroupBox("Tuning & Mix") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tune (st)").frame(width: 100, alignment: .leading).font(.subheadline)
                            Stepper("\(keyzone.tuneOffset)", value: $keyzone.tuneOffset, in: -24...24)
                                .onChange(of: keyzone.tuneOffset) { _, _ in onChange() }
                        }
                        HStack {
                            Text("Fine (¢)").frame(width: 100, alignment: .leading).font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.fineTune) },
                                               set: { keyzone.fineTune = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text("\(keyzone.fineTune)¢").frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Volume").frame(width: 100, alignment: .leading).font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.volume) },
                                               set: { keyzone.volume = UInt8($0); onChange() }), in: 0...99, step: 1)
                            Text("\(keyzone.volume)").frame(width: 30).font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Pan").frame(width: 100, alignment: .leading).font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.pan) },
                                               set: { keyzone.pan = Int8($0); onChange() }), in: -50...50, step: 1)
                            Text(keyzone.pan == 0 ? "C" : keyzone.pan > 0 ? "R\(keyzone.pan)" : "L\(abs(keyzone.pan))")
                                .frame(width: 35).font(.system(.caption, design: .monospaced))
                        }
                        Toggle("Loop", isOn: $keyzone.loopEnabled)
                            .onChange(of: keyzone.loopEnabled) { _, _ in onChange() }
                    }
                }
            }
        }
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
                ForEach(0..<128) { note in Text(noteName(UInt8(note))).tag(UInt8(note)) }
            }
            .labelsHidden()
            .onChange(of: value) { _, _ in onChange() }
        }
    }

    private func noteName(_ note: UInt8) -> String {
        "\(Self.noteNames[Int(note) % 12])\(Int(note) / 12 - 1) (\(note))"
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
                        Text(p.program.midiChannel == 0 ? "Omni" : "\(p.program.midiChannel)")
                    }.width(70)
                    TableColumn("Polyphony") { p in Text("\(p.program.polyphony)") }.width(80)
                }
            }
        }
    }
}
