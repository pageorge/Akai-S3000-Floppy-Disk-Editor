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

    @State private var programToDelete: AkaiProgramFile? = nil
    @State private var showDeleteProgramConfirm = false
    /// Multi-selection set for programs, mirroring selectedSampleIDs.
    @State private var selectedProgramIDs: Set<UUID> = []
    @State private var programSelectionAnchorID: UUID? = nil
    @State private var showBatchDeleteProgramConfirm = false
    /// True while THIS list has keyboard focus. Gates the key monitor below so
    /// it doesn't double-handle arrow/delete keys when focus has moved to
    /// another focusable list elsewhere in the app (e.g. a program's keyzone
    /// list), which has its own identical, focus-gated monitor.
    @State private var samplesExpanded: Bool = true
    @State private var programsExpanded: Bool = true
    @FocusState private var sidebarFocused: Bool
    @State private var isEditingVolumeName = false
    @State private var editedVolumeName = ""
    @FocusState private var volumeNameFieldFocused: Bool

    private var sampleToDeleteName: String {
        guard let s = sampleToDelete else { return "" }
        return s.header.name.isEmpty ? s.directoryEntry.name : s.header.name
    }

    private var programToDeleteName: String {
        guard let p = programToDelete else { return "" }
        return p.program.name.isEmpty ? p.directoryEntry.name : p.program.name
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

    /// Handle a program row tap, honouring Command (toggle) and Shift (range)
    /// modifiers, mirroring handleSampleTap.
    private func handleProgramTap(_ program: AkaiProgramFile) {
        let mods = NSEvent.modifierFlags
        selectedTab = .programs
        if mods.contains(.command) {
            if selectedProgramIDs.contains(program.id) {
                selectedProgramIDs.remove(program.id)
            } else {
                selectedProgramIDs.insert(program.id)
            }
            programSelectionAnchorID = program.id
            selectedProgramID = program.id
        } else if mods.contains(.shift), let anchor = programSelectionAnchorID,
                  let a = diskImage.programs.firstIndex(where: { $0.id == anchor }),
                  let b = diskImage.programs.firstIndex(where: { $0.id == program.id }) {
            let range = a <= b ? a...b : b...a
            selectedProgramIDs = Set(diskImage.programs[range].map { $0.id })
            selectedProgramID = program.id
        } else {
            selectedProgramIDs = [program.id]
            programSelectionAnchorID = program.id
            selectedProgramID = program.id
        }
    }

    private func deleteProgramSelection() {
        let ids = selectedProgramIDs
        guard !ids.isEmpty else { return }
        diskImage.deletePrograms(ids: ids)
        if let sel = selectedProgramID, ids.contains(sel) { selectedProgramID = nil }
        selectedProgramIDs.removeAll()
        programSelectionAnchorID = nil
    }

    /// Move the single selection up/down by `delta` (-1 = up, +1 = down) within
    /// whichever list is active (samples or programs), collapsing any existing
    /// multi-selection to the newly-focused row — mirrors Finder/list arrow-key
    /// navigation. If nothing is selected yet, arrow keys select the first row.
    private func moveSelection(by delta: Int) {
        if selectedTab == .programs {
            let list = diskImage.programs
            guard !list.isEmpty else { return }
            let newIndex: Int
            if let id = selectedProgramID, let idx = list.firstIndex(where: { $0.id == id }) {
                newIndex = max(0, min(list.count - 1, idx + delta))
            } else {
                newIndex = delta > 0 ? 0 : list.count - 1
            }
            let newID = list[newIndex].id
            selectedProgramID = newID
            selectedProgramIDs = [newID]
            programSelectionAnchorID = newID
        } else {
            let list = diskImage.samples
            guard !list.isEmpty else { return }
            let newIndex: Int
            if let id = selectedSampleID, let idx = list.firstIndex(where: { $0.id == id }) {
                newIndex = max(0, min(list.count - 1, idx + delta))
            } else {
                newIndex = delta > 0 ? 0 : list.count - 1
            }
            let newID = list[newIndex].id
            selectedTab = .samples
            selectedSampleID = newID
            selectedSampleIDs = [newID]
            selectionAnchorID = newID
        }
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

    /// Clone a program (with all settings: MIDI channel, polyphony, bend range,
    /// keyzones), mirroring cloneSample.
    private func cloneProgram(_ program: AkaiProgramFile) {
        do {
            let clone = try diskImage.cloneProgram(id: program.id)
            selectedTab = .programs
            selectedProgramID = clone.id
        } catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
        }
    }

    private func beginVolumeRename() {
        editedVolumeName = diskImage.diskName
        isEditingVolumeName = true
        diskImage.isEditingText = true
        DispatchQueue.main.async { volumeNameFieldFocused = true }
    }

    private func cancelVolumeRename() {
        isEditingVolumeName = false
        volumeNameFieldFocused = false
        diskImage.isEditingText = false
    }

    private func commitVolumeRename() {
        let clean = AkaiDiskImage.sanitizeName(editedVolumeName)
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else {
            cancelVolumeRename()
            return
        }
        if clean == diskImage.diskName {
            cancelVolumeRename()
            return
        }
        do {
            try diskImage.renameVolume(to: clean)
            cancelVolumeRename()
        } catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
            cancelVolumeRename()
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
            GreaseweazleSection(runner: greaseweazle, diskImage: diskImage)
            if diskImage.isLoaded {

                Section {
                    EmptyView()
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive.fill")
                            .foregroundStyle(.red)
                            .font(.title2)
                        if isEditingVolumeName {
                            TextField("Volume name", text: $editedVolumeName)
                                .textFieldStyle(.plain)
                                .font(.title3.weight(.semibold))
                                .focused($volumeNameFieldFocused)
                                .onChange(of: editedVolumeName) { _, newValue in
                                    let clean = AkaiDiskImage.sanitizeName(newValue)
                                    if clean != newValue { editedVolumeName = clean }
                                }
                                .onSubmit { commitVolumeRename() }
                                .onExitCommand { cancelVolumeRename() }
                            // Tick (commit)
                            Button { commitVolumeRename() } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Rename")
                            // X (cancel)
                            Button { cancelVolumeRename() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel")
                        } else {
                            Text(diskImage.diskName.isEmpty ? "Akai Disk" : diskImage.diskName)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            // Pen (begin edit)
                            Button { beginVolumeRename() } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rename volume")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 12)   // align RHS pencil with the sample/program pill content edge (row inset 4 + internal h-padding 8)
                }

                Section {
                    if samplesExpanded {
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
                    }
                } header: {
                    HStack {
                        Label("Samples (\(diskImage.samples.count))", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: samplesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { samplesExpanded.toggle() }
                        if samplesExpanded { selectedTab = .samples; selectedSampleID = nil; selectedSampleIDs.removeAll() }
                    }
                    .padding(.trailing, 12)
                }

                Section {
                    if programsExpanded {
                        ForEach(diskImage.programs) { prog in
                            SidebarProgramRow(
                                program: prog,
                                isSelected: selectedProgramIDs.contains(prog.id)
                                    || (selectedProgramIDs.isEmpty && selectedProgramID == prog.id),
                                selectedCount: selectedProgramIDs.count,
                                onTap: { handleProgramTap(prog) },
                                onDelete: {
                                    if selectedProgramIDs.count > 1 && selectedProgramIDs.contains(prog.id) {
                                        showBatchDeleteProgramConfirm = true
                                    } else {
                                        programToDelete = prog; showDeleteProgramConfirm = true
                                    }
                                },
                                onCreate: { createProgram() },
                                onClone: { cloneProgram(prog) }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Label("Programs (\(diskImage.programs.count))", systemImage: "pianokeys")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: programsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { programsExpanded.toggle() }
                        if programsExpanded { selectedTab = .programs; selectedProgramID = nil; selectedProgramIDs.removeAll() }
                    }
                    .padding(.trailing, 12)
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
        .focused($sidebarFocused)
        .navigationTitle("S3000 Editor")
        .onAppear {
            deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard self.sidebarFocused, !self.diskImage.isEditingText else { return event }

                // Arrow keys: move the single selection within whichever list is
                // active (126 = up, 125 = down), mirroring Finder/list navigation.
                if event.keyCode == 126 {
                    self.moveSelection(by: -1)
                    return nil
                }
                if event.keyCode == 125 {
                    self.moveSelection(by: 1)
                    return nil
                }

                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                // Multi-selection takes priority. Programs are checked first when
                // the programs tab is active and has a selection, otherwise samples.
                if self.selectedTab == .programs {
                    if self.selectedProgramIDs.count > 1 {
                        self.showBatchDeleteProgramConfirm = true
                        return nil
                    }
                    if let id = self.selectedProgramID,
                       let prog = self.diskImage.programs.first(where: { $0.id == id }) {
                        self.programToDelete = prog
                        self.showDeleteProgramConfirm = true
                        return nil
                    }
                }
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
        .confirmationDialog(
            "Delete \"\(programToDeleteName)\"?",
            isPresented: $showDeleteProgramConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Program", role: .destructive) {
                if let prog = programToDelete {
                    diskImage.deleteProgram(id: prog.id)
                    if selectedProgramID == prog.id { selectedProgramID = nil }
                    programToDelete = nil
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { programToDelete = nil }
        } message: {
            Text("This removes the program from the list. The disk image file is not modified until you save.")
        }
        .confirmationDialog(
            "Delete \(selectedProgramIDs.count) programs?",
            isPresented: $showBatchDeleteProgramConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedProgramIDs.count) Programs", role: .destructive) {
                deleteProgramSelection()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected programs from the list. The disk image file is not modified until you save.")
        }
        .alert("Couldn't complete", isPresented: $cloneSpaceAlert) {
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
    var selectedCount: Int = 0
    let onTap: () -> Void
    var onDelete: () -> Void = {}
    var onCreate: () -> Void = {}
    var onClone: () -> Void = {}

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
            Button(action: onClone) {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(action: onCreate) {
                Label("Create New Program", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                if selectedCount > 1 && isSelected {
                    Label("Delete \(selectedCount) Programs", systemImage: "trash")
                } else {
                    Label("Delete \"\(displayName)\"", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Greaseweazle Section

struct GreaseweazleSection: View {
    @ObservedObject var runner: GreaseweazleRunner
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var saveErrorAlert = false
    @State private var saveErrorMessage = ""

    /// The vivid Akai red used across the app's branding (logo, welcome screen).
    /// Using this exact RGB for the Write button fill guarantees it matches the
    /// "Open Disk Image" button rather than SwiftUI's flatter `Color.red`.
    private let akaiRed = Color(red: 0.91, green: 0, blue: 0.11)

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

                // Read / Write buttons.
                //
                // Both use an explicit Color fill + .buttonStyle(.plain) rather than
                // .borderedProminent. Inside a List, macOS only paints ONE bordered-
                // prominent button per container at full saturation (the key/default
                // button) and mutes the rest — which made "Write" render as a washed-
                // out pink next to the vivid blue "Read". Explicit fills sidestep that
                // heuristic. Write uses the exact Akai brand red (0.91, 0, 0.11) so it
                // matches the Open Disk Image button on the welcome screen.
                HStack(spacing: 8) {
                    Button {
                        readDisk()
                    } label: {
                        Label("Read", systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .opacity(runner.isBusy ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(runner.isBusy)

                    Button {
                        writeDisk()
                    } label: {
                        Label("Write", systemImage: "square.and.arrow.up.on.square")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(akaiRed)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .opacity(runner.isBusy ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
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
        .alert("Couldn't save before writing", isPresented: $saveErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
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
        // If a disk image is currently open in the app, write THAT file — after
        // auto-saving any pending edits — instead of asking the user to pick a
        // .img separately. Editing a sample only updates the in-memory buffer
        // (commitEditsToImage / applySampleEdits never touch the file on disk),
        // so writing the stale on-disk file silently skipped unsaved changes.
        // Auto-saving here closes that gap.
        if diskImage.isLoaded, let url = diskImage.imageURL {
            if diskImage.hasUnsavedChanges {
                do {
                    try diskImage.saveImageToDisk()
                } catch {
                    saveErrorMessage = "Your edits couldn't be saved, so the floppy would be written with stale data: \(error.localizedDescription)"
                    saveErrorAlert = true
                    return
                }
            }
            runner.write(from: url)
            return
        }
        // No disk image open — fall back to picking a .img file directly.
        guard let url = targetURL(forWriting: true) else { return }
        runner.write(from: url)
    }
}
