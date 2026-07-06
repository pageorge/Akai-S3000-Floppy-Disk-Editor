import SwiftUI

// MARK: - Multi List (sidebar-equivalent landing view)

/// Shown when the Multis tab is selected with nothing chosen yet: any REAL
/// multi files found on disk (name only, rename/delete -- all 16 parts are
/// editable once you select one, see MultiPlaceholderView), plus an entry
/// point to the in-memory preview MIX-page editor.
struct MultiListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedMultiID: UUID?

    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: UUID? = nil
    @State private var cloneErrorMessage = ""
    @State private var showCloneError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Multis").font(.title2.bold())
                Spacer()
                Text("\(diskImage.multis.count) files").foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if diskImage.multis.isEmpty {
                ContentUnavailableView("No Multis", systemImage: "square.stack.3d.up",
                    description: Text("Use New Multi to create one, or load a disk that has MULTI files."))
            } else {
                Table(diskImage.multis, selection: $selectedMultiID) {
                    TableColumn("Name") { mf in
                        Text(mf.multi.name.isEmpty ? "(unnamed)" : mf.multi.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Parts") { mf in
                        let active = mf.multi.parts.filter {
                            !$0.programName.trimmingCharacters(in: .whitespaces).isEmpty
                        }.count
                        Text(active == 0 ? "—" : "\(active) assigned")
                            .foregroundStyle(.secondary)
                    }.width(100)
                    TableColumn("Status") { _ in
                        Text("All 16 parts editable")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }.width(130)
                }
            }
        }
        .confirmationDialog("Delete this multi?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { diskImage.deleteMulti(id: id) }
                pendingDeleteID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("This removes the multi file from the disk. The disk image file is not modified until you save.")
        }
        .alert("Couldn't clone", isPresented: $showCloneError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloneErrorMessage)
        }
    }

    private func clone(_ mf: AkaiMultiFile) {
        do {
            let cloned = try diskImage.cloneMulti(id: mf.id)
            selectedMultiID = cloned.id
        } catch {
            cloneErrorMessage = error.localizedDescription
            showCloneError = true
        }
    }

    private func createNew() {
        if let created = try? diskImage.createMulti() {
            selectedMultiID = created.id
        }
    }
}

// MARK: - Placeholder for a real multi (all 16 parts editable)

/// Shown when a REAL multi file is selected. All 16 parts' confirmed fields
/// are decoded and editable (each saved back via applyMultiPartEdit) -- see
/// AkaiMultiFile's doc comment for what is and isn't confirmed yet.
struct MultiPlaceholderView: View {
    let multiFile: AkaiMultiFile
    @ObservedObject var diskImage: AkaiDiskImage

    @State private var parts: [AkaiMultiPart] = Array(repeating: AkaiMultiPart(), count: 16)
    @State private var saveError: String? = nil
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var nameFieldFocused: Bool

    /// Active part count for the subtitle.
    private var activeParts: Int {
        multiFile.multi.parts.filter {
            !$0.programName.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header — matches ProgramDetailView layout exactly
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Multi name", text: $editedName)
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
                            Text(multiFile.multi.name.isEmpty ? "(unnamed)" : multiFile.multi.name)
                                .font(.system(.title, design: .monospaced).bold())
                                .textSelection(.enabled)
                            Button { beginRename() } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.borderless)
                            .help("Rename multi")
                        }
                    }
                    Text("Multi · \(activeParts == 0 ? "no parts assigned" : "\(activeParts) part\(activeParts == 1 ? "" : "s") assigned")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.top, 4)
            }

            HStack(spacing: 8) {
                Text("Part").frame(width: 32, alignment: .leading)
                Text("Program").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                Text("Ch").frame(width: 50, alignment: .center)
                Text("Lev").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Text("Pan").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Text("Fx").frame(width: 60, alignment: .center)
                Text("Send").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal).padding(.top, 12)
            Divider()

            List {
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, _ in
                    MultiPartRow(
                        part: $parts[idx], partNumber: idx + 1,
                        availableProgramNames: diskImage.programs.map { $0.program.name },
                        onChange: { save(partIndex: idx) }
                    )
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            parts = multiFile.multi.parts
        }
    }

    private func beginRename() {
        editedName = multiFile.multi.name
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
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelRename(); return
        }
        _ = try? diskImage.renameMulti(id: multiFile.id, to: clean)
        cancelRename()
    }

    private func save(partIndex: Int) {
        do {
            try diskImage.applyMultiPartEdit(id: multiFile.id, partIndex: partIndex, part: parts[partIndex])
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - MIX-page editor (the actual feature request)

/// Replica of the real S3000XL's MULTI mode MIX page: 16 parts, each with a
/// program assignment, MIDI channel, level, pan, FX bus + send -- exactly the
/// columns shown on the hardware screen (Part#, Program/"?", Ch, Lev, Pan, Fx,
/// Send).
///
/// This editor is used in two places: (1) as a PREVIEW/PLANNING tool for a
/// brand-new multi with no backing file yet (this view, reached via "New Multi
/// (Preview)") -- genuinely can't be saved, since creating a new multi file
/// from scratch would need writing the multi-level header and per-part link
/// pointers, which remain unconfirmed; and (2) reused (as MultiPartRow) inside
/// MultiPlaceholderView for editing an EXISTING real multi file, which DOES
/// save for real, since all 16 parts' confirmed fields have known offsets.
struct MultiMixEditorView: View {
    @Binding var multi: AkaiMulti
    /// Names of real programs on the current disk, for the Program picker.
    let availableProgramNames: [String]
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MULTI:").foregroundStyle(.secondary)
                TextField("Name", text: $multi.name)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .frame(maxWidth: 220)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 12)

            // Column headers, matching the real hardware screen exactly.
            // Lev/Pan/Send get extra width since they're now slider+number
            // controls, not bare numbers — widths here must match MultiPartRow's
            // exactly so headers line up with their columns.
            HStack(spacing: 8) {
                Text("Part").frame(width: 32, alignment: .leading)
                Text("Program").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                Text("Ch").frame(width: 50, alignment: .center)
                Text("Lev").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Text("Pan").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Text("Fx").frame(width: 60, alignment: .center)
                Text("Send").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal).padding(.top, 12)
            Divider()

            List {
                ForEach(Array(multi.parts.enumerated()), id: \.offset) { idx, _ in
                    MultiPartRow(part: $multi.parts[idx], partNumber: idx + 1,
                                 availableProgramNames: availableProgramNames)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// One row of the MIX page -- one part's settings. Mirrors the real screen's
/// "?" convention for an unassigned program. `onChange`, if provided, fires
/// after every field edit (used by MultiPlaceholderView to save each part back
/// to a real file immediately; left nil in the pure in-memory preview editor).
private struct MultiPartRow: View {
    @Binding var part: AkaiMultiPart
    let partNumber: Int
    let availableProgramNames: [String]
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text("\(partNumber)").frame(width: 32, alignment: .leading)
                .font(.system(.body, design: .monospaced))

            Picker("", selection: $part.programName) {
                Text("?").tag("")
                ForEach(availableProgramNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(minWidth: 80, maxWidth: .infinity)
            .onChange(of: part.programName) { _, _ in onChange?() }

            Picker("", selection: $part.channel) {
                ForEach(1...16, id: \.self) { ch in
                    Text("\(ch)").tag(UInt8(ch))
                }
            }
            .labelsHidden()
            .frame(width: 50)
            .onChange(of: part.channel) { _, _ in onChange?() }

            HStack(spacing: 4) {
                Slider(value: .init(get: { Double(part.level) }, set: { part.level = UInt8($0); onChange?() }), in: 0...99, step: 1)
                Text("\(part.level)")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }
            .frame(minWidth: 90, maxWidth: .infinity)

            HStack(spacing: 4) {
                Slider(value: .init(get: { Double(part.pan) }, set: { part.pan = Int8($0); onChange?() }), in: -50...50, step: 1)
                Text(part.pan == 0 ? "MID" : part.pan > 0 ? "R\(part.pan)" : "L\(abs(part.pan))")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(minWidth: 90, maxWidth: .infinity)

            Picker("", selection: $part.fxBus) {
                ForEach(AkaiFxBus.allCases) { bus in
                    Text(bus.rawValue).tag(bus)
                }
            }
            .labelsHidden()
            .frame(width: 60)
            .onChange(of: part.fxBus) { _, _ in onChange?() }

            HStack(spacing: 4) {
                Slider(value: .init(get: { Double(part.fxSend) }, set: { part.fxSend = UInt8($0); onChange?() }), in: 0...99, step: 1)
                Text("\(part.fxSend)")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }
            .frame(minWidth: 90, maxWidth: .infinity)
        }
        .padding(.vertical, 2)
        .padding(.horizontal)
    }
}
