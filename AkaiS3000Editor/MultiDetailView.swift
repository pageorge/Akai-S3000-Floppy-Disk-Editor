import SwiftUI

// MARK: - Multi List (sidebar-equivalent landing view)

/// Shown when the Multis tab is selected with nothing chosen yet: any REAL
/// multi files found on disk (name only, rename/delete -- all 16 parts are
/// editable once you select one, see MultiPlaceholderView), plus an entry
/// point to the in-memory preview MIX-page editor.
struct MultiListView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedMultiID: UUID?
    let onCreatePreview: () -> Void

    @State private var renamingID: UUID? = nil
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Multis").font(.headline)
                Spacer()
                Button {
                    onCreatePreview()
                } label: {
                    Label("New Multi (Preview)", systemImage: "plus.square.on.square")
                }
            }
            .padding()

            if diskImage.multis.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No MULTI files on this disk")
                        .foregroundStyle(.secondary)
                    Text("Use \"New Multi (Preview)\" above to plan one before it has a file on disk -- see the banner on that screen for why a brand-new multi can't be saved to disk yet (existing multi files ARE fully editable, see above).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(diskImage.multis) { mf in
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            if renamingID == mf.id {
                                TextField("Name", text: $renameText, onCommit: {
                                    // @discardableResult only covers the function's
                                    // own return value, not the Optional that `try?`
                                    // wraps it in — explicitly discard to silence the
                                    // "result is unused" warning.
                                    _ = try? diskImage.renameMulti(id: mf.id, to: renameText)
                                    renamingID = nil
                                })
                                .textFieldStyle(.roundedBorder)
                            } else {
                                Text(mf.multi.name.isEmpty ? "(unnamed)" : mf.multi.name)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Spacer()
                            Text("All 16 parts editable")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedMultiID = mf.id }
                        .contextMenu {
                            Button("Rename") {
                                renameText = mf.multi.name
                                renamingID = mf.id
                            }
                            Button("Delete", role: .destructive) {
                                pendingDeleteID = mf.id
                                showDeleteConfirm = true
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Delete this multi?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { diskImage.deleteMulti(id: id) }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("This removes the multi file from the disk. The disk image file is not modified until you save.")
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
    let onBack: () -> Void

    @State private var parts: [AkaiMultiPart] = Array(repeating: AkaiMultiPart(), count: 16)
    @State private var saveError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("< Back to Multis") { onBack() }
                Spacer()
                Text(multiFile.multi.name)
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()

            GroupBox {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("All 16 parts below are decoded from this file's real bytes and ARE saved back when you edit them (confirmed by real-hardware byte-diff testing, including the per-part stride). Two small gaps within each part's own record, and the multi-level header, aren't decoded and are left untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal).padding(.top, 8)

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            // Column headers, matching the real hardware screen exactly (same
            // widths as MultiMixEditorView's so the look is consistent).
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
            // Preview banner -- see type doc comment for why this exists.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview only -- not saved to disk")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("This multi has no file on disk yet, so it can't be saved -- creating a brand-new multi file from scratch would need the multi-level header and per-part link pointers, which remain unconfirmed. Once you have a real multi file, opening it lets you edit and save all 16 parts for real.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onClose {
                    Button("Close Preview") { onClose() }
                }
            }
            .padding()
            .background(Color.orange.opacity(0.12))

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
