import SwiftUI

struct ProgramDetailView: View {
    let programFile: AkaiProgramFile
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var editedProgram: AkaiProgram
    @State private var selectedKeyzoneIndex: Int? = nil
    @State private var isDirty = false
    @State private var showAlert = false
    @State private var alertMsg = ""

    init(programFile: AkaiProgramFile, diskImage: AkaiDiskImage) {
        self.programFile = programFile
        self.diskImage = diskImage
        _editedProgram = State(initialValue: programFile.program)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editedProgram.name.isEmpty ? programFile.directoryEntry.name : editedProgram.name)
                        .font(.system(.title, design: .monospaced).bold())
                    Text("Program · \(editedProgram.keyzones.count) keyzones")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDirty {
                    Button("Revert") {
                        editedProgram = programFile.program
                        isDirty = false
                    }
                    .buttonStyle(.bordered)
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()

            Divider()

            HSplitView {
                // Left: program settings + keyzone list
                VStack(alignment: .leading, spacing: 0) {
                    // Program settings
                    GroupBox("Program Settings") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("MIDI Channel")
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: $editedProgram.midiChannel) {
                                    Text("Omni").tag(UInt8(0))
                                    ForEach(1..<17) { ch in
                                        Text("\(ch)").tag(UInt8(ch))
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: editedProgram.midiChannel) { _ in isDirty = true }
                            }
                            HStack {
                                Text("Polyphony")
                                    .frame(width: 100, alignment: .leading)
                                Stepper("\(editedProgram.polyphony)", value: $editedProgram.polyphony, in: 1...16)
                                    .onChange(of: editedProgram.polyphony) { _ in isDirty = true }
                            }
                            HStack {
                                Text("Bend Range")
                                    .frame(width: 100, alignment: .leading)
                                Stepper("\(editedProgram.bendRange) st", value: $editedProgram.bendRange, in: 0...12)
                                    .onChange(of: editedProgram.bendRange) { _ in isDirty = true }
                            }
                        }
                    }
                    .padding()

                    Divider()

                    // Keyzone list
                    HStack {
                        Text("Keyzones")
                            .font(.headline)
                        Spacer()
                        Button {
                            addKeyzone()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            if let idx = selectedKeyzoneIndex {
                                editedProgram.keyzones.remove(at: idx)
                                selectedKeyzoneIndex = nil
                                isDirty = true
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectedKeyzoneIndex == nil)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    List(selection: $selectedKeyzoneIndex) {
                        ForEach(Array(editedProgram.keyzones.enumerated()), id: \.offset) { idx, kz in
                            KeyzoneRow(keyzone: kz, sampleNames: diskImage.samples.map { $0.header.name })
                                .tag(idx)
                                .onTapGesture { selectedKeyzoneIndex = idx }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 280, maxWidth: 360)

                // Right: keyzone detail + piano keyboard
                VStack(alignment: .leading, spacing: 0) {
                    // Piano keyboard range display
                    PianoKeyboardView(
                        keyzones: editedProgram.keyzones,
                        selectedIndex: selectedKeyzoneIndex
                    )
                    .frame(height: 140)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    // Selected keyzone editor
                    if let idx = selectedKeyzoneIndex, idx < editedProgram.keyzones.count {
                        KeyzoneEditorView(
                            keyzone: $editedProgram.keyzones[idx],
                            sampleNames: diskImage.samples.map {
                                $0.header.name.isEmpty ? $0.directoryEntry.name : $0.header.name
                            },
                            onChange: { isDirty = true }
                        )
                        .padding()
                    } else {
                        ContentUnavailableView(
                            "Select a Keyzone",
                            systemImage: "pianokeys",
                            description: Text("Select a keyzone from the list to edit its properties")
                        )
                    }
                }
            }
        }
        .alert("Result", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMsg)
        }
    }

    private func addKeyzone() {
        let newKZ = AkaiProgramKeyzone(
            sampleName: diskImage.samples.first?.header.name ?? "NO NAME",
            lowKey: 0,
            highKey: 127,
            rootNote: 60,
            tuneOffset: 0,
            fineTune: 0,
            volume: 99,
            pan: 0,
            loopEnabled: false,
            velocityLow: 0,
            velocityHigh: 127
        )
        editedProgram.keyzones.append(newKZ)
        selectedKeyzoneIndex = editedProgram.keyzones.count - 1
        isDirty = true
    }

    private func saveChanges() {
        var updatedFile = programFile
        updatedFile.program = editedProgram
        do {
            try diskImage.updateProgramInImage(programFile: updatedFile)
            isDirty = false
            alertMsg = "Program saved successfully."
            showAlert = true
        } catch {
            alertMsg = error.localizedDescription
            showAlert = true
        }
    }
}

// MARK: - Keyzone Row

struct KeyzoneRow: View {
    let keyzone: AkaiProgramKeyzone
    let sampleNames: [String]

    var body: some View {
        HStack(spacing: 8) {
            // Key range indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue.opacity(0.7))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(keyzone.sampleName.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : keyzone.sampleName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(midiNoteName(keyzone.lowKey))–\(midiNoteName(keyzone.highKey))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Root: \(midiNoteName(keyzone.rootNote))")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Vel: \(keyzone.velocityLow)–\(keyzone.velocityHigh)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(note) / 12 - 1
        return "\(names[Int(note) % 12])\(octave)"
    }
}

// MARK: - Keyzone Editor

struct KeyzoneEditorView: View {
    @Binding var keyzone: AkaiProgramKeyzone
    let sampleNames: [String]
    let onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keyzone Settings")
                    .font(.headline)

                // Sample picker
                GroupBox("Sample") {
                    Picker("Sample", selection: $keyzone.sampleName) {
                        ForEach(sampleNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: keyzone.sampleName) { _ in onChange() }
                }

                // Key range
                GroupBox("Key Range") {
                    VStack(alignment: .leading, spacing: 10) {
                        MidiKeyPicker(label: "Low Key", value: $keyzone.lowKey, onChange: onChange)
                        MidiKeyPicker(label: "High Key", value: $keyzone.highKey, onChange: onChange)
                        MidiKeyPicker(label: "Root Note", value: $keyzone.rootNote, onChange: onChange)
                    }
                }

                // Velocity
                GroupBox("Velocity") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Low Velocity")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.velocityLow) },
                                               set: { keyzone.velocityLow = UInt8($0); onChange() }),
                                   in: 0...127, step: 1)
                            Text("\(keyzone.velocityLow)")
                                .frame(width: 30)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("High Velocity")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.velocityHigh) },
                                               set: { keyzone.velocityHigh = UInt8($0); onChange() }),
                                   in: 0...127, step: 1)
                            Text("\(keyzone.velocityHigh)")
                                .frame(width: 30)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                // Tuning & Mix
                GroupBox("Tuning & Mix") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Tune (st)")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Stepper("\(keyzone.tuneOffset)", value: $keyzone.tuneOffset, in: -24...24)
                                .onChange(of: keyzone.tuneOffset) { _ in onChange() }
                        }
                        HStack {
                            Text("Fine (¢)")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.fineTune) },
                                               set: { keyzone.fineTune = Int8($0); onChange() }),
                                   in: -50...50, step: 1)
                            Text("\(keyzone.fineTune)¢")
                                .frame(width: 35)
                                .font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Volume")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.volume) },
                                               set: { keyzone.volume = UInt8($0); onChange() }),
                                   in: 0...99, step: 1)
                            Text("\(keyzone.volume)")
                                .frame(width: 30)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Pan")
                                .frame(width: 100, alignment: .leading)
                                .font(.subheadline)
                            Slider(value: .init(get: { Double(keyzone.pan) },
                                               set: { keyzone.pan = Int8($0); onChange() }),
                                   in: -50...50, step: 1)
                            Text(keyzone.pan == 0 ? "C" : keyzone.pan > 0 ? "R\(keyzone.pan)" : "L\(abs(keyzone.pan))")
                                .frame(width: 35)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Toggle("Loop", isOn: $keyzone.loopEnabled)
                            .onChange(of: keyzone.loopEnabled) { _ in onChange() }
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
            Text(label)
                .frame(width: 80, alignment: .leading)
                .font(.subheadline)
            Picker("", selection: $value) {
                ForEach(0..<128) { note in
                    Text(noteName(UInt8(note))).tag(UInt8(note))
                }
            }
            .labelsHidden()
            .onChange(of: value) { _ in onChange() }
        }
    }

    private func noteName(_ note: UInt8) -> String {
        let octave = Int(note) / 12 - 1
        return "\(Self.noteNames[Int(note) % 12])\(octave) (\(note))"
    }
}

// MARK: - Program List

struct ProgramListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedProgramID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Programs")
                    .font(.title2.bold())
                Spacer()
                Text("\(diskImage.programs.count) files")
                    .foregroundStyle(.secondary)
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
                    TableColumn("Keyzones") { p in
                        Text("\(p.program.keyzones.count)")
                    }
                    .width(80)
                    TableColumn("MIDI Ch.") { p in
                        Text(p.program.midiChannel == 0 ? "Omni" : "\(p.program.midiChannel)")
                    }
                    .width(70)
                    TableColumn("Polyphony") { p in
                        Text("\(p.program.polyphony)")
                    }
                    .width(80)
                }
            }
        }
    }
}
