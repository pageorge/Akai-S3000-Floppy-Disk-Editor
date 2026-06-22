import SwiftUI

struct SidebarView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @ObservedObject var greaseweazle: GreaseweazleRunner
    @Binding var selectedTab: ContentView.SidebarTab
    @Binding var selectedSampleID: UUID?
    @Binding var selectedProgramID: UUID?

    @State private var sampleToDelete: AkaiSample? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteKeyMonitor: Any? = nil
    /// Multi-selection set for batch operations. The single `selectedSampleID`
    /// still drives the detail view; this set tracks the broader selection.
    @State private var selectedSampleIDs: Set<UUID> = []
    /// Anchor for shift-click range selection (last plain-clicked row).
    @State private var selectionAnchorID: UUID? = nil
    @State private var showBatchDeleteConfirm = false
    @State private var cloneSpaceAlert = false
    @State private var cloneSpaceMessage = ""

    private var sampleToDeleteName: String {
        guard let s = sampleToDelete else { return "" }
        return s.header.name.isEmpty ? s.directoryEntry.name : s.header.name
    }

    /// Handle a row tap, honouring Command (toggle) and Shift (range) modifiers.
    private func handleSampleTap(_ sample: AkaiSample) {
        let mods = NSEvent.modifierFlags
        selectedTab = .samples
        if mods.contains(.command) {
            // Toggle this row in/out of the multi-selection.
            if selectedSampleIDs.contains(sample.id) {
                selectedSampleIDs.remove(sample.id)
            } else {
                selectedSampleIDs.insert(sample.id)
            }
            selectionAnchorID = sample.id
            selectedSampleID = sample.id
        } else if mods.contains(.shift), let anchor = selectionAnchorID,
                  let a = diskImage.samples.firstIndex(where: { $0.id == anchor }),
                  let b = diskImage.samples.firstIndex(where: { $0.id == sample.id }) {
            // Select the contiguous range between anchor and this row.
            let range = a <= b ? a...b : b...a
            selectedSampleIDs = Set(diskImage.samples[range].map { $0.id })
            selectedSampleID = sample.id
        } else {
            // Plain click: single selection.
            selectedSampleIDs = [sample.id]
            selectionAnchorID = sample.id
            selectedSampleID = sample.id
        }
    }

    private func deleteSelection() {
        let ids = selectedSampleIDs
        guard !ids.isEmpty else { return }
        diskImage.deleteSamples(ids: ids)
        if let sel = selectedSampleID, ids.contains(sel) { selectedSampleID = nil }
        selectedSampleIDs.removeAll()
        selectionAnchorID = nil
    }

    /// Clone one or more samples (with all settings). If the right-clicked sample
    /// is part of a multi-selection, clone the whole selection; otherwise just it.
    private func cloneSample(_ sample: AkaiSample) {
        let ids: [UUID]
        if selectedSampleIDs.count > 1 && selectedSampleIDs.contains(sample.id) {
            // Preserve on-disk order for predictable naming/placement.
            ids = diskImage.samples.map { $0.id }.filter { selectedSampleIDs.contains($0) }
        } else {
            ids = [sample.id]
        }

        // Pre-check: will the whole batch fit (free blocks AND directory slots)?
        let targets = ids.compactMap { id in diskImage.samples.first(where: { $0.id == id }) }
        let blocksRequired = targets.reduce(0) { $0 + diskImage.blocksNeeded(for: $1) }
        let blocksFree = diskImage.freeBlockCount
        if blocksRequired > blocksFree {
            let needKB = blocksRequired         // 1 block = 1 KB
            let freeKB = blocksFree
            cloneSpaceMessage = targets.count > 1
                ? "Cloning these \(targets.count) samples needs \(needKB) KB but only \(freeKB) KB is free. Free up space or clone fewer samples."
                : "Cloning this sample needs \(needKB) KB but only \(freeKB) KB is free."
            cloneSpaceAlert = true
            return
        }

        var lastCloneID: UUID? = nil
        for id in ids {
            if let clone = try? diskImage.cloneSample(id: id) {
                lastCloneID = clone.id
            } else {
                // Ran out of directory slots (or other error) mid-batch.
                cloneSpaceMessage = "Couldn't clone every sample — the disk directory may be full."
                cloneSpaceAlert = true
                break
            }
        }

        if let last = lastCloneID {
            selectedTab = .samples
            selectedSampleID = last
            selectedSampleIDs = [last]
            selectionAnchorID = last
        }
    }

    /// Create a new empty program and select it.
    private func createProgram() {
        do {
            let prog = try diskImage.createProgram()
            selectedTab = .programs
            selectedProgramID = prog.id
        } catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
        }
    }

    @ViewBuilder
    private func sampleContextMenu(sample: AkaiSample) -> some View {
        let name = sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
        Button(role: .destructive) {
            sampleToDelete = sample
            showDeleteConfirm = true
        } label: {
            Label("Delete \"\(name)\"", systemImage: "trash")
        }
    }

    var body: some View {
        List {
            GreaseweazleSection(runner: greaseweazle)
            if diskImage.isLoaded {

                Section {
                    EmptyView()
                } header: {
                    HStack {
                        Image(systemName: "internaldrive.fill").foregroundStyle(.red)
                        Text(diskImage.diskName.isEmpty ? "Akai Disk" : diskImage.diskName)
                            .font(.headline).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(diskImage.samples) { sample in
                        SidebarSampleRow(
                            sample: sample,
                            isSelected: selectedSampleIDs.contains(sample.id)
                                || (selectedSampleIDs.isEmpty && selectedSampleID == sample.id),
                            selectedCount: selectedSampleIDs.count,
                            onTap: { handleSampleTap(sample) },
                            onDelete: {
                                if selectedSampleIDs.count > 1 && selectedSampleIDs.contains(sample.id) {
                                    showBatchDeleteConfirm = true
                                } else {
                                    sampleToDelete = sample; showDeleteConfirm = true
                                }
                            },
                            onClone: { cloneSample(sample) }
                        )
                    }
                } header: {
                    Label("Samples (\(diskImage.samples.count))", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture { selectedTab = .samples; selectedSampleID = nil; selectedSampleIDs.removeAll() }
                }

                Section {
                    ForEach(diskImage.programs) { prog in
                        SidebarProgramRow(
                            program: prog,
                            isSelected: selectedProgramID == prog.id,
                            onTap: { selectedTab = .programs; selectedProgramID = prog.id },
                            onCreate: { createProgram() }
                        )
                    }
                } header: {
                    Label("Programs (\(diskImage.programs.count))", systemImage: "pianokeys")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture { selectedTab = .programs; selectedProgramID = nil }
                        .contextMenu {
                            Button { createProgram() } label: {
                                Label("Create New Program", systemImage: "plus.square.on.square")
                            }
                        }
                }

                Section {
                    Label("Disk Info", systemImage: "info.circle")
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTab = .diskInfo }
                }

            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No Disk Loaded", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("Open a .img file to begin")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("S3000 Editor")
        .onAppear {
            deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard (event.keyCode == 51 || event.keyCode == 117),
                      !self.diskImage.isEditingText else { return event }
                // Multi-selection takes priority.
                if self.selectedSampleIDs.count > 1 {
                    self.showBatchDeleteConfirm = true
                    return nil
                }
                if let id = self.selectedSampleID,
                   let sample = self.diskImage.samples.first(where: { $0.id == id }) {
                    self.sampleToDelete = sample
                    self.showDeleteConfirm = true
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let m = deleteKeyMonitor { NSEvent.removeMonitor(m); deleteKeyMonitor = nil }
        }
        .confirmationDialog(
            "Delete \"\(sampleToDeleteName)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Sample", role: .destructive) {
                if let sample = sampleToDelete {
                    diskImage.deleteSample(id: sample.id)
                    if selectedSampleID == sample.id { selectedSampleID = nil }
                    sampleToDelete = nil
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { sampleToDelete = nil }
        } message: {
            Text("This removes the sample from the list. The disk image file is not modified until you save.")
        }
        .confirmationDialog(
            "Delete \(selectedSampleIDs.count) samples?",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedSampleIDs.count) Samples", role: .destructive) {
                deleteSelection()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected samples from the list. The disk image file is not modified until you save.")
        }
        .alert("Couldn’t complete", isPresented: $cloneSpaceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloneSpaceMessage)
        }
    }
}

struct SidebarSampleRow: View {
    let sample: AkaiSample
    let isSelected: Bool
    var selectedCount: Int = 0
    let onTap: () -> Void
    let onDelete: () -> Void
    var onClone: () -> Void = {}

    private var displayName: String {
        sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(isSelected ? .white : .red)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("\(sample.header.sampleRate / 1000)kHz · \(midiNoteName(sample.header.midiRootNote))")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.red : Color.clear))
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(action: onClone) {
                if selectedCount > 1 && isSelected {
                    Label("Clone \(selectedCount) Samples", systemImage: "plus.square.on.square")
                } else {
                    Label("Clone", systemImage: "plus.square.on.square")
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                if selectedCount > 1 && isSelected {
                    Label("Delete \(selectedCount) Samples", systemImage: "trash")
                } else {
                    Label("Delete \"\(displayName)\"", systemImage: "trash")
                }
            }
        }
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }
}

struct SidebarProgramRow: View {
    let program: AkaiProgramFile
    let isSelected: Bool
    let onTap: () -> Void
    var onCreate: () -> Void = {}

    private var displayName: String {
        program.program.name.isEmpty ? program.directoryEntry.name : program.program.name
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pianokeys.inverse")
                .foregroundStyle(isSelected ? .white : .purple)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("\(program.program.keyzones.count) keyzone\(program.program.keyzones.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.purple : Color.clear))
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(action: onCreate) {
                Label("Create New Program", systemImage: "plus.square.on.square")
            }
        }
    }
}

// MARK: - Greaseweazle Section

struct GreaseweazleSection: View {
    @ObservedObject var runner: GreaseweazleRunner

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // Drive picker
                Picker("Drive", selection: $runner.drive) {
                    ForEach(GreaseweazleRunner.Drive.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(runner.isBusy)

                // Format picker
                VStack(alignment: .leading, spacing: 2) {
                    Text("Format").font(.caption2).foregroundStyle(.secondary)
                    Picker("Format", selection: $runner.format) {
                        ForEach(GreaseweazleRunner.DiskFormat.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden()
                    .disabled(runner.isBusy)
                }

                // Read / Write buttons
                HStack(spacing: 8) {
                    Button {
                        readDisk()
                    } label: {
                        Label("Read", systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)   // match Drive B (system accent blue)
                    .disabled(runner.isBusy)

                    Button {
                        writeDisk()
                    } label: {
                        Label("Write", systemImage: "square.and.arrow.up.on.square")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)   // match Samples highlight
                    .disabled(runner.isBusy)
                }

                if runner.isBusy {
                    Button(role: .destructive) { runner.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Image(systemName: "opticaldiscdrive.fill").foregroundStyle(.indigo)
                Text("Greaseweazle").font(.headline)
                if runner.isBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func targetURL(forWriting: Bool) -> URL? {
        if forWriting {
            // Writing TO a floppy: pick an existing .img to send.
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.init(filenameExtension: "img")!, .data]
            panel.title = "Choose .img to write to floppy"
            return panel.runModal() == .OK ? panel.url : nil
        } else {
            // Reading FROM a floppy: choose where to save the new .img.
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "img")!]
            panel.title = "Save floppy read as .img"
            panel.nameFieldStringValue = "akai_disk.img"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    private func readDisk() {
        guard let url = targetURL(forWriting: false) else { return }
        runner.read(to: url)
    }

    private func writeDisk() {
        guard let url = targetURL(forWriting: true) else { return }
        runner.write(from: url)
    }
}
