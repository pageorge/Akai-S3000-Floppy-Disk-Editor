import SwiftUI

struct SidebarView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @ObservedObject var greaseweazle: GreaseweazleRunner
    @Binding var selectedTab: ContentView.SidebarTab
    @Binding var selectedSampleID: UUID?
    @Binding var selectedProgramID: UUID?
    @Binding var selectedMultiID: UUID?

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
    @State private var drumPresetPartialAlert = false
    @State private var drumPresetPartialMessage = ""

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
    @State private var multisExpanded: Bool = true
    @State private var multiToDelete: AkaiMultiFile? = nil
    @State private var showDeleteMultiConfirm = false
    @FocusState private var sidebarFocused: Bool
    @State private var isEditingVolumeName = false
    @State private var editedVolumeName = ""
    @FocusState private var volumeNameFieldFocused: Bool
    @AppStorage("lowQualityImport") private var lowQualityImport = false

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
        selectedProgramID = nil
        selectedProgramIDs.removeAll()
        selectedMultiID = nil
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
        selectedSampleID = nil
        selectedSampleIDs.removeAll()
        selectedMultiID = nil
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

    /// EXPERIMENTAL: make a shared-PCM clone of the sample (shares audio blocks,
    /// no copy) and select it. Non-standard on-disk layout — for hardware testing
    /// on a throwaway floppy only. See
    /// AkaiDiskImage.cloneSampleSharedPCM_EXPERIMENTAL.
    private func cloneSampleSharedPCM(_ sample: AkaiSample) {
        do {
            let clone = try diskImage.cloneSampleSharedPCM_EXPERIMENTAL(id: sample.id)
            selectedTab = .samples
            selectedSampleID = clone.id
            selectedSampleIDs = [clone.id]
            selectionAnchorID = clone.id
        } catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
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

    /// Create a new drum program instantly (no picker), seeded with one
    /// single-key C1 keyzone so it reads as — and persists as — a drum kit.
    /// Mirrors createProgram(). See AkaiDiskImage.createDrumProgram.
    private func createDrumProgram() {
        do {
            let prog = try diskImage.createDrumProgram()
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

    /// Open a file picker for a single WAV/AIFF, import it, and create a
    /// program with one keyzone spanning the full keyboard (C0–G8).
    private func createPresetFromSample() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Choose sample for preset"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let rawName = url.deletingPathExtension().lastPathComponent
        let programName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))

        let prog: AkaiProgramFile
        do { prog = try diskImage.createProgram(name: programName) }
        catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
            return
        }

        let loFi = lowQualityImport
        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let wavData = try Data(contentsOf: url)
                let (pcmData, sampleRate, numChannels) = try Self.parseWAVMinimal(wavData)
                let baseName = AkaiDiskImage.sanitizeName(
                    url.deletingPathExtension().lastPathComponent)
                var monoData: Data; var monoName: String
                if numChannels >= 2 {
                let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                monoData = left
                monoName = AkaiDiskImage.sanitizeNamePreservingEnd(baseName, maxLen: 10) + "-L"
                } else {
                monoData = pcmData
                monoName = String(baseName.prefix(12))
                }
                let finalRate: UInt32
                if loFi {
                    let (loPCM, loRate) = Self.applyLoFi(pcm: monoData, fromRate: sampleRate)
                    monoData = loPCM; finalRate = loRate
                } else {
                    finalRate = UInt32(sampleRate)
                }
                let sample = try diskImage.addImportedSample(
                    name: monoName, sampleRate: finalRate,
                    numChannels: 1, pcmData: monoData)
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
                    selectedTab = .programs
                    selectedProgramID = prog.id
                    selectedProgramIDs = [prog.id]
                    programSelectionAnchorID = prog.id
                }
            } catch {
                DispatchQueue.main.async {
                    cloneSpaceMessage = error.localizedDescription
                    cloneSpaceAlert = true
                }
            }
        }
    }

    /// Open a folder picker, then import all WAV/AIFF files alphabetically as
    /// one-shot drum keyzones (each mapped to its own key starting at C0),
    /// creating a new program named after the folder. Partial imports (disk full
    /// mid-batch) are reported via an alert; the successfully-imported samples
    /// and their keyzones are still committed.
    private func createDrumPresetFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose folder for drum preset"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        // Derive program name from folder name: strip spaces, sanitize to Akai
        // charset, truncate to 12 chars.
        let rawName = folderURL.lastPathComponent
        let programName = AkaiDiskImage.sanitizeName(String(rawName.prefix(12)))

        // Collect audio files sorted alphabetically.
        let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let audioURLs = contents
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !audioURLs.isEmpty else {
            cloneSpaceMessage = "No audio files found in that folder."
            cloneSpaceAlert = true
            return
        }

        // Create the program first so it exists to add keyzones to.
        let prog: AkaiProgramFile
        do { prog = try diskImage.createProgram(name: programName) }
        catch {
            cloneSpaceMessage = error.localizedDescription
            cloneSpaceAlert = true
            return
        }

        let loFi = lowQualityImport
        // Import samples and build keyzones on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var keyzones: [AkaiProgramKeyzone] = []
            var nextNote: Int = 36   // C1
            var hitDiskLimit = false
            var limitMessage = ""

            for url in audioURLs {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                do {
                    let wavData = try Data(contentsOf: url)
                    let (pcmData, sampleRate, numChannels) = try Self.parseWAVMinimal(wavData)
                    let baseName = AkaiDiskImage.sanitizeName(
                        url.deletingPathExtension().lastPathComponent)
                    var monoData: Data; var monoName: String
                    if numChannels >= 2 {
                        let (left, _) = AkaiDiskImage.deinterleaveStereo(pcmData, channels: numChannels)
                        monoData = left
                        monoName = AkaiDiskImage.sanitizeNamePreservingEnd(baseName, maxLen: 10) + "-L"
                    } else {
                        monoData = pcmData
                        monoName = String(baseName.prefix(12))
                    }
                    let finalRate: UInt32
                    if loFi {
                        let (loPCM, loRate) = Self.applyLoFi(pcm: monoData, fromRate: sampleRate)
                        monoData = loPCM; finalRate = loRate
                    } else {
                        finalRate = UInt32(sampleRate)
                    }
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
                        pitchMode: 0))   // TRACK — bendable, unity at its own key
                    nextNote += 1
                } catch {
                    // Disk full or directory full — stop importing.
                    hitDiskLimit = true
                    let imported = keyzones.count
                    let total = audioURLs.count
                    limitMessage = "Disk is full — only \(imported) of \(total) samples could be imported. The program has been created with those samples."
                    break
                }
            }

            // Apply all keyzones to the program in one shot.
            DispatchQueue.main.async {
                if !keyzones.isEmpty {
                    var updated = diskImage.programs.first(where: { $0.id == prog.id }) ?? prog
                    updated.program.keyzones = keyzones
                    diskImage.applyProgramEdits(updated)
                    diskImage.hasUnsavedChanges = true
                }
                selectedTab = .programs
                selectedProgramID = prog.id
                selectedProgramIDs = [prog.id]
                programSelectionAnchorID = prog.id
                if hitDiskLimit {
                    drumPresetPartialMessage = limitMessage
                    drumPresetPartialAlert = true
                }
            }
        }
    }

    /// Minimal WAV/AIFF parser — extracts PCM data, sample rate, channel count.
    /// Mirrors the per-struct parsers in the drop zones but lives here so
    /// SidebarView can use it without depending on a struct that may not exist.
    private static func applyLoFi(pcm: Data, fromRate: Int) -> (Data, UInt32) {
        AkaiDiskImage.applyLoFi(pcm: pcm, fromRate: fromRate)
    }

    private static func parseWAVMinimal(_ data: Data) throws -> (Data, Int, Int) {
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
            let size = Int(data.readLE32(at: offset + 4)); offset += 8
            if id == "fmt " {
                numChannels = Int(data.readLE16(at: offset + 2))
                sampleRate  = Int(data.readLE32(at: offset + 4))
                bitsPerSample = Int(data.readLE16(at: offset + 14))
            } else if id == "data" {
                pcmData = data.subdata(in: offset..<min(offset + size, data.count))
            }
            offset += size + (size % 2)
        }
        guard !pcmData.isEmpty else {
            throw NSError(domain: "WAV", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio data"])
        }
        if bitsPerSample == 24 {
            let bytesPerFrame = 3 * numChannels
            var out = Data(); out.reserveCapacity((pcmData.count / bytesPerFrame) * 2 * numChannels)
            var i = 0
            while i + bytesPerFrame <= pcmData.count {
                for ch in 0..<numChannels { out.append(pcmData[i + ch*3 + 1]); out.append(pcmData[i + ch*3 + 2]) }
                i += bytesPerFrame
            }
            return (out, sampleRate, numChannels)
        }
        return (pcmData, sampleRate, numChannels)
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
                diskNameSection
                samplesSection
                programsSection
                multisSection
                diskInfoSection
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
                guard !self.diskImage.isEditingText else { return event }
                // Bow out entirely while a program's keyzone list has an active
                // selection. NSEvent local monitors fire in REGISTRATION order
                // (oldest first) — this monitor is registered once at app launch,
                // so without this guard it always intercepts arrow/delete keys
                // before ProgramDetailView's own monitor (registered fresh each
                // time a program is opened) ever sees them. See
                // AkaiDiskImage.keyzoneEditorActive's doc comment for the full story.
                guard !self.diskImage.keyzoneEditorActive else { return event }
                // Only handle arrow/delete if the sidebar actually has something
                // selected — if the keyzone list is focused it has its own monitor
                // and will handle the event first (returning nil), so we won't
                // reach here for those keys anyway.
                let hasSidebarSelection = self.selectedSampleID != nil
                    || !self.selectedSampleIDs.isEmpty
                    || self.selectedProgramID != nil
                    || !self.selectedProgramIDs.isEmpty
                    || self.selectedMultiID != nil
                guard hasSidebarSelection else { return event }

                if event.keyCode == 126 { self.moveSelection(by: -1); return nil }
                if event.keyCode == 125 { self.moveSelection(by:  1); return nil }

                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                if self.selectedTab == .multis {
                    if let id = self.selectedMultiID,
                       let mf = self.diskImage.multis.first(where: { $0.id == id }) {
                        self.multiToDelete = mf
                        self.showDeleteMultiConfirm = true
                        return nil
                    }
                }
                if self.selectedTab == .programs {
                    if self.selectedProgramIDs.count > 1 {
                        self.showBatchDeleteProgramConfirm = true; return nil
                    }
                    if let id = self.selectedProgramID,
                       let prog = self.diskImage.programs.first(where: { $0.id == id }) {
                        self.programToDelete = prog
                        self.showDeleteProgramConfirm = true
                        return nil
                    }
                }
                if self.selectedSampleIDs.count > 1 {
                    self.showBatchDeleteConfirm = true; return nil
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
        .confirmationDialog("Delete \"\(sampleToDeleteName)\"?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
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
        .confirmationDialog("Delete \(selectedSampleIDs.count) samples?",
            isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
            Button("Delete \(selectedSampleIDs.count) Samples", role: .destructive) { deleteSelection() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected samples from the list. The disk image file is not modified until you save.")
        }
        .confirmationDialog("Delete \"\(programToDeleteName)\"?",
            isPresented: $showDeleteProgramConfirm, titleVisibility: .visible) {
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
        .confirmationDialog("Delete \(selectedProgramIDs.count) programs?",
            isPresented: $showBatchDeleteProgramConfirm, titleVisibility: .visible) {
            Button("Delete \(selectedProgramIDs.count) Programs", role: .destructive) { deleteProgramSelection() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected programs from the list. The disk image file is not modified until you save.")
        }
        .confirmationDialog("Delete multi?",
            isPresented: $showDeleteMultiConfirm, titleVisibility: .visible) {
            Button("Delete Multi", role: .destructive) {
                if let mf = multiToDelete {
                    diskImage.deleteMulti(id: mf.id)
                    if selectedMultiID == mf.id { selectedMultiID = nil }
                    multiToDelete = nil
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { multiToDelete = nil }
        } message: {
            Text("This removes the multi file from the disk. The disk image file is not modified until you save.")
        }
        .alert("Couldn't complete", isPresented: $cloneSpaceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloneSpaceMessage)
        }
        .alert("Partial import", isPresented: $drumPresetPartialAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(drumPresetPartialMessage)
        }
    }

    // MARK: - Sidebar sections (extracted to keep body type-checkable)

    @ViewBuilder private var diskNameSection: some View {
        Section {
            EmptyView()
        } header: {
            HStack(spacing: 6) {
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
                    Button { commitVolumeRename() } label: {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                    }.buttonStyle(.plain).help("Rename")
                    Button { cancelVolumeRename() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Cancel")
                } else {
                    Text(diskImage.diskName.isEmpty ? "Akai Disk" : diskImage.diskName)
                        .font(.title2.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { beginVolumeRename() } label: {
                        Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Rename volume")
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 12)
        }
    }

    @ViewBuilder private var samplesSection: some View {
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
                        onClone: { cloneSample(sample) },
                        onCloneSharedPCM: { cloneSampleSharedPCM(sample) }
                    )
                }
            }
        } header: {
            HStack {
                let isActive = selectedTab == .samples && selectedSampleID == nil
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color(red: 0.91, green: 0, blue: 0.11))
                    Text("Samples (\(diskImage.samples.count))")
                        .font(.body)
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { samplesExpanded.toggle() }
                } label: {
                    Image(systemName: samplesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !samplesExpanded {
                    withAnimation(.easeInOut(duration: 0.2)) { samplesExpanded = true }
                }
                selectedTab = .samples
                selectedSampleID = nil
                selectedSampleIDs.removeAll()
            }
            .padding(.trailing, 12)
        }
    }

    @ViewBuilder private var programsSection: some View {
        Section {
            if programsExpanded {
                ForEach(diskImage.programs) { prog in
                    SidebarProgramRow(
                        program: prog,
                        isDrumOverride: diskImage.isDrumProgram(name: prog.program.name.isEmpty ? prog.directoryEntry.name : prog.program.name),
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
                        onClone: { cloneProgram(prog) },
                        onCreatePreset: { createPresetFromSample() },
                        onCreateDrumPreset: { createDrumPresetFromFolder() }
                    )
                }
            }
        } header: {
            HStack {
                let isActive = selectedTab == .programs && selectedProgramID == nil
                HStack(spacing: 6) {
                    Image(systemName: "pianokeys")
                        .foregroundStyle(Color.purple)
                    Text("Programs (\(diskImage.programs.count))")
                        .font(.body)
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { programsExpanded.toggle() }
                } label: {
                    Image(systemName: programsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !programsExpanded {
                    withAnimation(.easeInOut(duration: 0.2)) { programsExpanded = true }
                }
                selectedTab = .programs
                selectedProgramID = nil
                selectedProgramIDs.removeAll()
            }
            .padding(.trailing, 12)
            .contextMenu {
                Button { createProgram() } label: {
                    Label("Create Program", systemImage: "plus.square.on.square")
                }
                Button { createDrumProgram() } label: {
                    Label("Create Drum Program", systemImage: drumKitSymbol)
                }
            }
        }
    }

    @ViewBuilder private var multisSection: some View {
        Section {
            if multisExpanded {
                ForEach(diskImage.multis) { mf in
                    SidebarMultiRow(
                        multiFile: mf,
                        isSelected: selectedMultiID == mf.id,
                        onTap: {
                            selectedTab = .multis
                            selectedMultiID = mf.id
                            selectedSampleID = nil
                            selectedSampleIDs.removeAll()
                            selectionAnchorID = nil
                            selectedProgramID = nil
                            selectedProgramIDs.removeAll()
                            programSelectionAnchorID = nil
                        },
                        onClone: {
                            do {
                                let cloned = try diskImage.cloneMulti(id: mf.id)
                                selectedTab = .multis
                                selectedMultiID = cloned.id
                            } catch {
                                cloneSpaceMessage = error.localizedDescription
                                cloneSpaceAlert = true
                            }
                        },
                        onCreate: {
                            if let created = try? diskImage.createMulti() {
                                selectedTab = .multis
                                selectedMultiID = created.id
                            }
                        },
                        onDelete: { multiToDelete = mf; showDeleteMultiConfirm = true },
                        onRename: {
                            selectedTab = .multis
                            selectedMultiID = mf.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                NotificationCenter.default.post(name: .beginMultiRename, object: mf.id)
                            }
                        }
                    )
                }
            }
        } header: {
            let count = diskImage.multis.count
            HStack {
                let isActive = selectedTab == .multis && selectedMultiID == nil
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(Color.teal)
                    Text("Multis (\(count))")
                        .font(.body)
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { multisExpanded.toggle() }
                } label: {
                    Image(systemName: multisExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !multisExpanded {
                    withAnimation(.easeInOut(duration: 0.2)) { multisExpanded = true }
                }
                selectedTab = .multis
                selectedMultiID = nil
            }
            .padding(.trailing, 12)
            .contextMenu {
                Button {
                    if let created = try? diskImage.createMulti() {
                        selectedTab = .multis
                        selectedMultiID = created.id
                    }
                } label: {
                    Label("Create Multi", systemImage: "plus.square.on.square")
                }
            }
        }
    }

    @ViewBuilder private var diskInfoSection: some View {
        Section {
            EmptyView()
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .foregroundStyle(Color.white)
                Text("Disk Info")
                    .font(.body)
                    .foregroundStyle(selectedTab == .diskInfo ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedTab = .diskInfo
                selectedSampleID = nil
                selectedSampleIDs.removeAll()
                selectionAnchorID = nil
                selectedProgramID = nil
                selectedProgramIDs.removeAll()
                programSelectionAnchorID = nil
                selectedMultiID = nil
            }
            .padding(.trailing, 12)
        }
    }
}

// Greaseweazle brand purple — sampled directly from the opticaldiscdrive.fill
// SF Symbol as rendered on macOS dark mode. Shared with the welcome screen pill.
internal let greaseweazlePurple = Color(red: 0.55, green: 0.50, blue: 0.80)

private let akaiRed = Color(red: 0.91, green: 0, blue: 0.11)
/// Brown accent used to distinguish drum-kit programs (all single-key keyzones)
/// from melodic/piano programs (purple). Shared by the sidebar row and the
/// program detail header.
let akaiDrumBrown = Color(red: 0.55, green: 0.36, blue: 0.20)
/// SF Symbol used for drum-kit programs — a 3×3 pad grid reads as an MPC/drum
/// machine, versus `pianokeys` for melodic programs.
let drumKitSymbol = "circle.grid.3x3.fill"

struct SidebarSampleRow: View {
    let sample: AkaiSample
    let isSelected: Bool
    var selectedCount: Int = 0
    let onTap: () -> Void
    let onDelete: () -> Void
    var onClone: () -> Void = {}
    var onCloneSharedPCM: () -> Void = {}

    private var displayName: String {
        sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(isSelected ? .white : akaiRed)
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
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? akaiRed : Color.clear))
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onDrag {
            NSItemProvider(object: displayName as NSString)
        }
        .contextMenu {
            Button(action: onClone) {
                if selectedCount > 1 && isSelected {
                    Label("Clone \(selectedCount) Samples", systemImage: "plus.square.on.square")
                } else {
                    Label("Clone", systemImage: "plus.square.on.square")
                }
            }
            // EXPERIMENTAL shared-PCM clone — makes a second sample that shares
            // this one's audio blocks (no copy). Non-standard on disk; for
            // testing on a throwaway floppy whether the S3000 can share PCM.
            // See AkaiDiskImage.cloneSampleSharedPCM_EXPERIMENTAL.
            Button(role: .destructive, action: onCloneSharedPCM) {
                Label("Clone Shared PCM (experimental)", systemImage: "exclamationmark.triangle")
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
        // -2 matches the S3000XL's own octave display (C3 = MIDI 60), consistent
        // with SampleDetailView / MidiKeyPicker / KeyzoneRow. Previously -1 here,
        // which showed everything an octave too high (e.g. C4 for C3).
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
    }
}

struct SidebarProgramRow: View {
    let program: AkaiProgramFile
    var isDrumOverride: Bool = false
    let isSelected: Bool
    var selectedCount: Int = 0
    let onTap: () -> Void
    var onDelete: () -> Void = {}
    var onCreate: () -> Void = {}
    var onClone: () -> Void = {}
    var onCreatePreset: () -> Void = {}
    var onCreateDrumPreset: () -> Void = {}

    private var displayName: String {
        program.program.name.isEmpty ? program.directoryEntry.name : program.program.name
    }

    /// Drum kits get a brown pad-grid look; melodic programs stay purple pianokeys.
    private var isDrum: Bool { program.program.isDrumKit || isDrumOverride }
    private var accent: Color { isDrum ? akaiDrumBrown : .purple }
    private var iconName: String { isDrum ? drumKitSymbol : "pianokeys.inverse" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(isSelected ? .white : accent)
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
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? accent : Color.clear))
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(action: onClone) {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(action: onCreate) {
                Label("Create Program", systemImage: "plus.square.on.square")
            }
            Button(action: onCreatePreset) {
                Label("Create Preset from Sample", systemImage: "square.and.arrow.down.on.square")
            }
            Button(action: onCreateDrumPreset) {
                Label("Create Drum Preset from Folder", systemImage: "folder.badge.plus")
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

struct SidebarMultiRow: View {
    let multiFile: AkaiMultiFile
    let isSelected: Bool
    let onTap: () -> Void
    var onClone: () -> Void = {}
    var onCreate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onRename: () -> Void = {}

    private var displayName: String {
        multiFile.multi.name.isEmpty ? "(unnamed)" : multiFile.multi.name
    }

    private var activeParts: Int {
        multiFile.multi.parts.filter { !$0.programName.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(isSelected ? .white : .teal)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(activeParts == 0 ? "no parts assigned" : "\(activeParts) part\(activeParts == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.teal : Color.clear))
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(action: onClone) {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(action: onCreate) {
                Label("Create Multi", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete \"\(displayName)\"", systemImage: "trash")
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
    @State private var showSaveBeforeWriteConfirm = false

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
                Image(systemName: "opticaldiscdrive.fill").foregroundStyle(greaseweazlePurple).font(.title2)
                Text("Greaseweazle").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                if runner.isBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 12)
        }
        .alert("Couldn't save before writing", isPresented: $saveErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
        .confirmationDialog("Save changes before writing to floppy?",
            isPresented: $showSaveBeforeWriteConfirm, titleVisibility: .visible) {
            Button("Save and Write") {
                guard let url = diskImage.imageURL else { return }
                do {
                    try diskImage.saveImageToDisk()
                    runner.write(from: url, lastUsedTrack: diskImage.lastUsedTrack())
                } catch {
                    saveErrorMessage = "Couldn't save: \(error.localizedDescription)"
                    saveErrorAlert = true
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your disk image has unsaved changes. Save now so the floppy gets the latest version.")
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
        if diskImage.isLoaded, let url = diskImage.imageURL {
            if diskImage.hasUnsavedChanges {
                showSaveBeforeWriteConfirm = true
                return
            }
            runner.write(from: url, lastUsedTrack: diskImage.lastUsedTrack())
            return
        }
        guard let url = targetURL(forWriting: true) else { return }
        runner.write(from: url)
    }
}
