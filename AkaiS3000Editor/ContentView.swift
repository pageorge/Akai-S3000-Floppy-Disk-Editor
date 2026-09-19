import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @ObservedObject var greaseweazle: GreaseweazleRunner
    @State private var selectedTab: SidebarTab = .samples
    @State private var selectedSampleID: UUID? = nil
    @State private var selectedSampleIDs: Set<UUID> = []
    @State private var selectedProgramID: UUID? = nil
    @State private var selectedMultiID: UUID? = nil
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @State private var toast: ToastData?
    @State private var pendingOpenAction: (() -> Void)? = nil
    @State private var showingUnsavedChangesConfirm = false

    @State private var isContentReady = true

    private func scheduleContentReady() {
        isContentReady = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            isContentReady = true
        }
    }

    @State private var duplicateSampleAlert = false
    @State private var duplicateSampleMessage = ""
    @State private var duplicateSampleCount = 0
    @State private var duplicateSampleHasOtherFiles = false
    @State private var pendingSampleImport: (() -> Void)? = nil
    @AppStorage("lowQualityImport") private var lowQualityImport = false

    enum SidebarTab: String, CaseIterable {
        case samples = "Samples"
        case programs = "Programs"
        case multis = "Multis"
        case diskInfo = "Disk Info"

        var icon: String {
            switch self {
            case .samples: return "waveform"
            case .programs: return "pianokeys"
            case .multis: return "square.stack.3d.up"
            case .diskInfo: return "externaldrive.badge.questionmark"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            SidebarView(
                diskImage: diskImage,
                greaseweazle: greaseweazle,
                selectedTab: $selectedTab,
                selectedSampleID: $selectedSampleID,
                selectedSampleIDs: $selectedSampleIDs,
                selectedProgramID: $selectedProgramID,
                selectedMultiID: $selectedMultiID
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                if diskImage.isLoaded, let url = diskImage.imageURL {
                    DiskPathBar(url: url)
                    Divider()
                }
                Group {
                    if greaseweazle.isBusy || !greaseweazle.logLines.isEmpty {
                        GreaseweazleLogView(runner: greaseweazle)
                    } else if !diskImage.isLoaded {
                        WelcomeView(diskImage: diskImage)
                    } else if !isContentReady {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch selectedTab {
                        case .samples:
                            if let id = selectedSampleID,
                               let sample = diskImage.samples.first(where: { $0.id == id }) {
                                SampleDetailView(
                                    sample: sample,
                                    selectedSampleIDs: selectedSampleIDs,
                                    diskImage: diskImage
                                )
                                .id(id)
                            } else {
                                SampleListView(diskImage: diskImage, selectedSampleID: $selectedSampleID)
                            }
                        case .programs:
                            if let id = selectedProgramID,
                               let prog = diskImage.programs.first(where: { $0.id == id }) {
                                ProgramDetailView(programFile: prog, diskImage: diskImage)
                                    .id(id)
                            } else {
                                ProgramListView(diskImage: diskImage, selectedProgramID: $selectedProgramID)
                            }
                        case .multis:
                            if let id = selectedMultiID,
                               let real = diskImage.multis.first(where: { $0.id == id }) {
                                MultiPlaceholderView(multiFile: real, diskImage: diskImage)
                            } else {
                                MultiListView(diskImage: diskImage, selectedMultiID: $selectedMultiID)
                            }
                        case .diskInfo:
                            DiskInfoView(diskImage: diskImage)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if diskImage.isLoaded {
                        Button {
                            saveAll()
                        } label: {
                            Label("Save Image", systemImage: "square.and.arrow.down")
                        }
                        .help("Save all changes to disk image")
                        .keyboardShortcut("s", modifiers: .command)

                        Button {
                            closeDiskImage()
                        } label: {
                            Text("×").font(.system(size: 22))
                        }
                        .help("Close this disk image and return to the start screen")
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiskImage)) { _ in
            openDiskImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createDiskImage)) { _ in
            createDiskImage()
        }
        .onChange(of: selectedTab) { _, _ in
            if !greaseweazle.isBusy { greaseweazle.clearLog() }
            scheduleContentReady()
        }
        .onChange(of: selectedSampleID) { _, _ in
            if !greaseweazle.isBusy { greaseweazle.clearLog() }
            scheduleContentReady()
        }
        .onChange(of: selectedProgramID) { _, _ in
            if !greaseweazle.isBusy { greaseweazle.clearLog() }
            scheduleContentReady()
        }
        .onChange(of: selectedMultiID) { _, _ in
            if !greaseweazle.isBusy { greaseweazle.clearLog() }
            scheduleContentReady()
        }
        .onAppear {
            // When a Greaseweazle read finishes, auto-load the freshly read .img.
            greaseweazle.onReadComplete = { url in
                do {
                    try diskImage.load(from: url)
                    UserDefaults.standard.set(url.path, forKey: "lastOpenedImagePath")
                    selectedSampleID = nil
                    selectedProgramID = nil
                    selectedMultiID = nil
                    greaseweazle.clearLog()
                    toast = ToastData(message: "Loaded \(url.lastPathComponent)")
                } catch {
                    toast = ToastData(message: "Read OK but couldn't load: \(error.localizedDescription)", isError: true)
                }
            }
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .toast($toast)
        .alert(duplicateSampleCount == 1 ? "Sample already exists" : "Samples already exist", isPresented: $duplicateSampleAlert) {
            Button("Import Anyway") { pendingSampleImport?(); pendingSampleImport = nil }
            Button(duplicateSampleHasOtherFiles ? "Skip" : "Cancel", role: .cancel) { pendingSampleImport = nil }
        } message: {
            Text(duplicateSampleMessage)
        }
        .confirmationDialog(
            "You have unsaved changes",
            isPresented: $showingUnsavedChangesConfirm,
            titleVisibility: .visible
        ) {
            Button("Save") {
                do {
                    try diskImage.saveImageToDisk()
                    pendingOpenAction?()
                    pendingOpenAction = nil
                } catch {
                    alertMessage = error.localizedDescription
                    showingAlert = true
                    pendingOpenAction = nil
                }
            }
            Button("Don't Save", role: .destructive) {
                pendingOpenAction?()
                pendingOpenAction = nil
            }
            Button("Cancel", role: .cancel) { pendingOpenAction = nil }
        } message: {
            Text("If you continue without saving, your changes to the disk image will be lost.")
        }
    }

    /// Close the current disk image and return to the welcome screen. Respects
    /// unsaved changes by routing through the same confirmation dialog as Open/New.
    private func closeDiskImage() {
        let doClose = {
            diskImage.closeImage()
            selectedSampleID = nil
            selectedProgramID = nil
            selectedMultiID = nil
            selectedTab = .samples
            greaseweazle.clearLog()
        }
        if diskImage.hasUnsavedChanges {
            pendingOpenAction = doClose
            showingUnsavedChangesConfirm = true
            return
        }
        doClose()
    }

    private func saveAll() {
        do {
            try diskImage.saveImageToDisk()
            toast = ToastData(message: "Disk image saved")
        } catch {
            toast = ToastData(message: error.localizedDescription, isError: true)
        }
    }

    private func openDiskImage() {
        if diskImage.hasUnsavedChanges {
            pendingOpenAction = { performOpenDiskImage() }
            showingUnsavedChangesConfirm = true
            return
        }
        performOpenDiskImage()
    }

    private func createDiskImage() {
        if diskImage.hasUnsavedChanges {
            pendingOpenAction = { performCreateDiskImage() }
            showingUnsavedChangesConfirm = true
            return
        }
        performCreateDiskImage()
    }

    private func performCreateDiskImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "img")!]
        panel.title = "Create New Akai S3000 Disk Image"
        panel.nameFieldStringValue = "new_disk.img"
        panel.prompt = "Create"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                // Use the file's base name (uppercased, Akai-clamped) as the volume label.
                let vol = url.deletingPathExtension().lastPathComponent
                try diskImage.createBlankImage(at: url, volumeName: vol)
                UserDefaults.standard.set(url.path, forKey: "lastOpenedImagePath")
                selectedSampleID = nil
                selectedProgramID = nil
                selectedMultiID = nil
                toast = ToastData(message: "Created \(url.lastPathComponent)")
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func performOpenDiskImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "img")!,
                                     .init(filenameExtension: "ima")!,
                                     .data]
        panel.title = "Open Akai S3000 Disk Image"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try diskImage.load(from: url)
                UserDefaults.standard.set(url.path, forKey: "lastOpenedImagePath")
                selectedSampleID = nil
                selectedProgramID = nil
                selectedMultiID = nil
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func importWAV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.title = "Import WAV as Sample"

        if panel.runModal() == .OK {
            for url in panel.urls {
                importSample(from: url)
            }
        }
    }

    /// Import a single audio file at `url` as a new sample in the loaded disk.
    /// `release` (if provided) is called once the file read completes — used to
    /// drop security-scoped access for dropped files.
    private func applyLoFi(pcm: Data, fromRate: Int) -> (Data, UInt32) {
        AkaiDiskImage.applyLoFi(pcm: pcm, fromRate: fromRate)
    }

    private func importSample(from url: URL, release: (() -> Void)? = nil) {
        let loFi = lowQualityImport
        DispatchQueue.global(qos: .userInitiated).async {
            defer { release?() }
            // Read file once.
            guard let wavData = try? Data(contentsOf: url),
                  wavData.count > 44,
                  wavData[0..<4] == Data("RIFF".utf8),
                  wavData[8..<12] == Data("WAVE".utf8) else {
                // Not a WAV — try importAndAddSample which handles AIFF etc.
                do {
                    let s = try self.diskImage.importAndAddSample(from: url)
                    DispatchQueue.main.async { self.selectedSampleID = s.id; self.selectedTab = .samples }
                } catch {
                    DispatchQueue.main.async { self.alertMessage = error.localizedDescription; self.showingAlert = true }
                }
                return
            }
            // Parse WAV once.
            var offset = 12; var sampleRate = 44100; var numChannels = 1; var bitsPerSample = 16; var pcm = Data()
            while offset + 8 <= wavData.count {
                let id = String(bytes: wavData[offset..<offset+4], encoding: .ascii) ?? ""
                let size = Int(wavData.readLE32(at: offset + 4)); offset += 8
                if id == "fmt " { numChannels = Int(wavData.readLE16(at: offset+2)); sampleRate = Int(wavData.readLE32(at: offset+4)); bitsPerSample = Int(wavData.readLE16(at: offset+14)) }
                else if id == "data" { pcm = wavData.subdata(in: offset..<min(offset+size, wavData.count)) }
                offset += size + (size % 2)
            }
            guard !pcm.isEmpty else { return }
            // Normalise to 16-bit LE mono.
            let pcm16: Data
            if bitsPerSample == 24 {
                // 24-bit: 3 bytes per sample, take top 2 (bytes 1 and 2) for 16-bit.
                let bytesPerFrame = (bitsPerSample / 8) * numChannels
                var out = Data(); out.reserveCapacity((pcm.count / bytesPerFrame) * 2 * numChannels)
                var i = 0
                while i + bytesPerFrame <= pcm.count {
                    for ch in 0..<numChannels {
                        let base = i + ch * 3
                        // 24-bit LE: bytes are [lo, mid, hi]. Top 16 = mid+hi.
                        out.append(pcm[base + 1])
                        out.append(pcm[base + 2])
                    }
                    i += bytesPerFrame
                }
                pcm16 = out
            } else {
                pcm16 = pcm
            }
            let left = numChannels >= 2 ? AkaiDiskImage.deinterleaveStereo(pcm16, channels: numChannels).0 : pcm16
            let right = numChannels >= 2 ? AkaiDiskImage.deinterleaveStereo(pcm16, channels: numChannels).1 : nil
            // Duplicate check on left channel.
            let dupes = self.diskImage.duplicateSampleNames(forPCM: left)
            if !dupes.isEmpty {
                DispatchQueue.main.async {
                    self.duplicateSampleCount = dupes.count
                    self.duplicateSampleHasOtherFiles = false
                    self.duplicateSampleMessage = "\(url.lastPathComponent) already exists on the disk. Import anyway?"
                    self.pendingSampleImport = {
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.doImport(url: url, left: left, right: right, sampleRate: sampleRate, numChannels: numChannels, loFi: loFi)
                        }
                    }
                    self.duplicateSampleAlert = true
                }
                return
            }
            self.doImport(url: url, left: left, right: right, sampleRate: sampleRate, numChannels: numChannels, loFi: loFi)
        }
    }

    private func doImport(url: URL, left: Data, right: Data?, sampleRate: Int, numChannels: Int, loFi: Bool) {
        do {
            let raw = url.deletingPathExtension().lastPathComponent
            let stem = AkaiDiskImage.sanitizeName(raw)
            let isStereo = numChannels >= 2
            let stemL = isStereo ? AkaiDiskImage.sanitizeNamePreservingEnd(raw, maxLen: 10) + "-L" : stem
            let stemR = AkaiDiskImage.sanitizeNamePreservingEnd(raw, maxLen: 10) + "-R"
            if loFi {
                let (loPCM, loRate) = applyLoFi(pcm: left, fromRate: sampleRate)
                let newL = try diskImage.addImportedSample(name: stemL, sampleRate: loRate, numChannels: 1, pcmData: loPCM)
                DispatchQueue.main.async { self.selectedSampleID = newL.id; self.selectedTab = .samples }
                if isStereo, let r = right {
                    let (roPCM, roRate) = applyLoFi(pcm: r, fromRate: sampleRate)
                    let newR = try diskImage.addImportedSample(name: stemR, sampleRate: roRate, numChannels: 1, pcmData: roPCM)
                    DispatchQueue.main.async { self.selectedSampleID = newR.id }
                }
            } else {
                let newL = try diskImage.addImportedSample(name: stemL, sampleRate: UInt32(sampleRate), numChannels: 1, pcmData: left)
                DispatchQueue.main.async { self.selectedSampleID = newL.id; self.selectedTab = .samples }
                if isStereo, let r = right {
                    let newR = try diskImage.addImportedSample(name: stemR, sampleRate: UInt32(sampleRate), numChannels: 1, pcmData: r)
                    DispatchQueue.main.async { self.selectedSampleID = newR.id }
                }
            }
        } catch {
            DispatchQueue.main.async { self.alertMessage = error.localizedDescription; self.showingAlert = true }
        }
    }

    /// Handle files dropped anywhere on the detail area.
    /// - .img/.ima files open as a disk image (respecting unsaved-changes).
    /// - audio files import as new samples (only when a disk is already loaded).
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()

            // Known type buckets.
            let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]
            let diskExts:  Set<String> = ["img", "ima"]

            DispatchQueue.main.async {
                // Start access on the main actor and hold it across the read,
                // releasing only once the file has been fully consumed.
                let accessing = url.startAccessingSecurityScopedResource()
                let release = { if accessing { url.stopAccessingSecurityScopedResource() } }

                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

                if isDir.boolValue {
                    // Folder dropped — import all audio files inside it as samples.
                    guard diskImage.isLoaded else { release(); return }
                    importFolder(url: url, release: release)
                } else if diskExts.contains(ext) {
                    handleDroppedDisk(url: url, release: release)
                } else if audioExts.contains(ext) {
                    guard diskImage.isLoaded else {
                        release()
                        alertMessage = "Open a disk image first, then drop an audio file to add it as a sample."
                        showingAlert = true
                        return
                    }
                    importSample(from: url, release: release)
                } else if diskImage.isLoaded {
                    importSample(from: url, release: release)
                } else {
                    handleDroppedDisk(url: url, release: release)
                }
            }
        }
        return true
    }

    private func importFolder(url: URL, release: @escaping () -> Void) {
        let audioExts: Set<String> = ["wav", "wave", "aif", "aiff", "aifc"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { release(); return }
        let audioURLs = contents
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        release() // folder access done; each file gets its own security scope
        guard !audioURLs.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var clean: [URL] = []
            var dupeURLs: [URL] = []
            var dupeFileNames: [String] = []

            for fileURL in audioURLs {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                guard let wavData = try? Data(contentsOf: fileURL),
                      wavData.count > 44,
                      wavData[0..<4] == Data("RIFF".utf8),
                      wavData[8..<12] == Data("WAVE".utf8) else { clean.append(fileURL); continue }
                var offset = 12; var numChannels = 1; var pcm = Data()
                while offset + 8 <= wavData.count {
                    let id = String(bytes: wavData[offset..<offset+4], encoding: .ascii) ?? ""
                    let size = Int(wavData.readLE32(at: offset + 4)); offset += 8
                    if id == "fmt " { numChannels = Int(wavData.readLE16(at: offset+2)) }
                    else if id == "data" { pcm = wavData.subdata(in: offset..<min(offset+size, wavData.count)) }
                    offset += size + (size % 2)
                }
                guard !pcm.isEmpty else { clean.append(fileURL); continue }
                let checkPCM = numChannels >= 2 ? AkaiDiskImage.deinterleaveStereo(pcm, channels: numChannels).0 : pcm
                let dupes = diskImage.duplicateSampleNames(forPCM: checkPCM)
                if dupes.isEmpty {
                    clean.append(fileURL)
                } else {
                    dupeURLs.append(fileURL)
                    dupeFileNames.append(fileURL.lastPathComponent)
                }
            }

            // Import non-duplicate files immediately.
            for fileURL in clean {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                if let s = try? diskImage.importAndAddSample(from: fileURL) {
                    DispatchQueue.main.async { selectedSampleID = s.id; selectedTab = .samples }
                }
                if accessing { fileURL.stopAccessingSecurityScopedResource() }
            }

            guard !dupeURLs.isEmpty else { return }

            DispatchQueue.main.async {
                duplicateSampleCount = dupeURLs.count
                duplicateSampleHasOtherFiles = !clean.isEmpty
                duplicateSampleMessage = "\(dupeFileNames.joined(separator: ", ")) already exist\(dupeURLs.count == 1 ? "s" : "") on the disk. Import anyway?"
                pendingSampleImport = {
                    DispatchQueue.global(qos: .userInitiated).async {
                        for fileURL in dupeURLs {
                            let accessing = fileURL.startAccessingSecurityScopedResource()
                            if let s = try? diskImage.importAndAddSample(from: fileURL) {
                                DispatchQueue.main.async { selectedSampleID = s.id; selectedTab = .samples }
                            }
                            if accessing { fileURL.stopAccessingSecurityScopedResource() }
                        }
                    }
                }
                duplicateSampleAlert = true
            }
        }
    }

    private func handleDroppedDisk(url: URL, release: @escaping () -> Void) {
        let openIt = {
            defer { release() }
            do {
                try diskImage.load(from: url)
                UserDefaults.standard.set(url.path, forKey: "lastOpenedImagePath")
                selectedSampleID = nil
                selectedProgramID = nil
                selectedMultiID = nil
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
        if diskImage.hasUnsavedChanges {
            // Defer the open (and the access release) until the user resolves the dialog.
            pendingOpenAction = openIt
            showingUnsavedChangesConfirm = true
        } else {
            openIt()
        }
    }
}
