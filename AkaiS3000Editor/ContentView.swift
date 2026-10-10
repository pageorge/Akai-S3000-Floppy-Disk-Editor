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
    @State private var showingEmuImport = false
    @State private var emuBank: EmuBank?

    /// What this window was opened for. Kept in sync with what it shows
    /// (.open(url) once an image is loaded) so SwiftUI can bring an existing
    /// window forward instead of opening the same file twice, and restore
    /// windows on relaunch.
    @Binding var request: DiskWindowRequest?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var windowID = UUID()
    @State private var handledInitialRequest = false

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
                    if ownsGreaseweazleLog && (greaseweazle.isBusy || !greaseweazle.logLines.isEmpty) {
                        GreaseweazleLogView(runner: greaseweazle)
                    } else if !diskImage.isLoaded {
                        WelcomeView(diskImage: diskImage,
                                    onNew: { createDiskImage() },
                                    onOpen: { openDiskImage() },
                                    onOpenRecent: { open($0) })
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
                        .help("Close this disk image and return to the start screen (⌘W closes the window)")
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        // File-menu commands act on whichever window is focused.
        .focusedSceneValue(\.diskWindowActions, DiskWindowActions(
            newImage: { createDiskImage() },
            openImage: { openDiskImage() },
            importEmu: { triggerEmuImport() },
            isLoaded: diskImage.isLoaded))
        .background(DiskWindowCloseGuard(
            diskImage: diskImage,
            isEdited: diskImage.hasUnsavedChanges,
            title: windowTitle,
            shouldClose: { UnsavedChangesPrompt.confirm(diskImage, action: "closing") }))
        .onChange(of: greaseweazle.isBusy) { _, busy in
            // The read/write was started from the key window — that's this one.
            if busy, controlActiveState == .key { claimGreaseweazle() }
        }
        .onDisappear {
            DiskImageRegistry.shared.unregister(diskImage)
        }
        .sheet(isPresented: $showingEmuImport) {
            EmuImportSheet(diskImage: diskImage, preloadedBank: emuBank) { message in
                selectedTab = .programs
                selectedProgramID = nil
                toast = ToastData(message: message)
            }
        }
        .onChange(of: selectedTab) { _, _ in
            clearOwnGreaseweazleLog()
            scheduleContentReady()
        }
        .onChange(of: selectedSampleID) { _, _ in
            clearOwnGreaseweazleLog()
            scheduleContentReady()
        }
        .onChange(of: selectedProgramID) { _, _ in
            clearOwnGreaseweazleLog()
            scheduleContentReady()
        }
        .onChange(of: selectedMultiID) { _, _ in
            clearOwnGreaseweazleLog()
            scheduleContentReady()
        }
        .onAppear {
            handleInitialRequest()
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importEmuDisks)) { _ in
            // Fired when the menu item is clicked from FileMenuButtons fallback.
            // Only the key window should respond.
            guard controlActiveState == .key else { return }
            triggerEmuImport()
        }
        .toast($toast)
        .alert(duplicateSampleCount == 1 ? "Sample already exists" : "Samples already exist", isPresented: $duplicateSampleAlert) {
            Button("Import Anyway") {
                NSLog("[IMPORT] ContentView duplicate prompt → Import Anyway")
                pendingSampleImport?(); pendingSampleImport = nil
            }
            Button(duplicateSampleHasOtherFiles ? "Skip" : "Cancel", role: .cancel) {
                NSLog("[IMPORT] ContentView duplicate prompt → %@", duplicateSampleHasOtherFiles ? "Skip" : "Cancel")
                pendingSampleImport = nil
            }
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

    // MARK: - Window: opening, creating, Greaseweazle ownership

    /// Window/tab title: the image's file name, e.g. "Vamp.img".
    private var windowTitle: String {
        guard diskImage.isLoaded, let url = diskImage.imageURL else { return "S3000 Editor" }
        return url.lastPathComponent
    }

    /// Act on what this window was opened for (runs once, when it appears).
    private func handleInitialRequest() {
        guard !handledInitialRequest else { return }
        handledInitialRequest = true
        DiskImageRegistry.shared.register(diskImage)
        switch request {
        case .open(let url)?:
            if !loadInPlace(url) { request = .empty(UUID()) }
        case .create?:
            // Let the window finish appearing before the save panel runs.
            DispatchQueue.main.async {
                if !performCreateDiskImage() { request = .empty(UUID()) }
            }
        default:
            break
        }
    }

    /// Open `url`: bring its window forward if it's already open, load it here
    /// if this window is empty, otherwise open it in a new window.
    private func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = DiskImageRegistry.shared.image(openAt: url) {
            if existing !== diskImage {
                openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.open(url))
            }
            return
        }
        if diskImage.isLoaded {
            openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.open(url))
        } else {
            loadInPlace(url)
        }
    }

    @discardableResult
    private func loadInPlace(_ url: URL) -> Bool {
        do {
            try diskImage.load(from: url)
            didLoad(url)
            return true
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
            return false
        }
    }

    /// Bookkeeping after this window loads or creates an image.
    private func didLoad(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "lastOpenedImagePath")
        selectedSampleID = nil
        selectedSampleIDs = []
        selectedProgramID = nil
        selectedMultiID = nil
        selectedTab = .samples
        request = .open(url.standardizedFileURL)
    }

    /// Only the window that started a Greaseweazle job shows its log. Before
    /// any job has been claimed, the key window shows messages (e.g. gw not found).
    private var ownsGreaseweazleLog: Bool {
        if let owner = greaseweazle.ownerWindowID { return owner == windowID }
        return controlActiveState == .key
    }

    private func clearOwnGreaseweazleLog() {
        if ownsGreaseweazleLog && !greaseweazle.isBusy { greaseweazle.clearLog() }
    }

    /// Take the Greaseweazle for this window: its log shows here, and a freshly
    /// read image loads here (or in a new window if this one already has an image).
    private func claimGreaseweazle() {
        greaseweazle.ownerWindowID = windowID
        greaseweazle.onReadComplete = { url in
            let url = url.standardizedFileURL
            greaseweazle.clearLog()
            if let existing = DiskImageRegistry.shared.image(openAt: url) {
                // The read just overwrote a file that's open somewhere — reload it.
                do {
                    try existing.load(from: url)
                } catch {
                    toast = ToastData(message: "Read OK but couldn't reload: \(error.localizedDescription)", isError: true)
                    return
                }
                if existing !== diskImage {
                    openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.open(url))
                }
            } else if diskImage.isLoaded {
                openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.open(url))
            } else if !loadInPlace(url) {
                return
            }
            toast = ToastData(message: "Loaded \(url.lastPathComponent)")
        }
    }

    // MARK: - Close / save

    /// Close the current disk image and return to the welcome screen. Respects
    /// unsaved changes by routing through the same confirmation dialog as Open/New.
    private func closeDiskImage() {
        let doClose = {
            diskImage.closeImage()
            selectedSampleID = nil
            selectedProgramID = nil
            selectedMultiID = nil
            selectedTab = .samples
            clearOwnGreaseweazleLog()
            request = .empty(UUID())
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

    /// Open one or more images. The first loads here if this window is empty;
    /// the rest (or all, if this window already has an image) get their own windows.
    private func openDiskImage() {
        for url in DiskWindow.chooseImages() { open(url) }
    }

    /// New blank image: here if this window is empty, otherwise in a new window.
    private func createDiskImage() {
        if diskImage.isLoaded {
            openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.create(UUID()))
        } else {
            performCreateDiskImage()
        }
    }

    /// Returns false if the user cancelled or creation failed.
    @discardableResult
    private func performCreateDiskImage() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "img")!]
        panel.title = "Create New Akai S3000 Disk Image"
        panel.nameFieldStringValue = "new_disk.img"
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // Creating over a file that's open in another window would leave two
        // windows on the same file (SwiftUI then closes one of them) and the
        // other window showing stale contents.
        if let other = DiskImageRegistry.shared.image(openAt: url), other !== diskImage {
            alertMessage = "“\(url.lastPathComponent)” is open in another window. Close it first, or choose a different name."
            showingAlert = true
            return false
        }
        do {
            // Use the file's base name (uppercased, Akai-clamped) as the volume label.
            let vol = url.deletingPathExtension().lastPathComponent
            try diskImage.createBlankImage(at: url, volumeName: vol)
            didLoad(url)
            toast = ToastData(message: "Created \(url.lastPathComponent)")
            return true
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
            return false
        }
    }

    private func triggerEmuImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.title = "Choose E-mu ESI Disk Images or Bank File"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let loaded = try EmuESIParser.load(urls: panel.urls)
            emuBank = loaded
            if !diskImage.isLoaded {
                let name = loaded.name.isEmpty ? "EMU IMPORT" : loaded.name
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(AkaiDiskImage.sanitizeName(name) + ".img")
                try diskImage.createBlankImage(at: tmpURL, volumeName: name)
            }
            showingEmuImport = true
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    private func importWAV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.title = "Import WAV as Sample"

        if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    /// Write pipeline output to the disk as mono samples (an -L/-R pair for stereo).
    private func addChannels(_ channels: [AudioImportPipeline.Channel]) {
        do {
            for ch in channels {
                let s = try diskImage.addImportedSample(name: ch.name, sampleRate: ch.sampleRate,
                                                        numChannels: 1, pcmData: ch.pcm,
                                                        forceName: true)
                DispatchQueue.main.async { self.selectedSampleID = s.id; self.selectedTab = .samples }
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
                    importFiles([url], release: release)
                } else if diskImage.isLoaded {
                    importFiles([url], release: release)
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
        importFiles(audioURLs)
    }

    /// Import one or more audio files as new samples. The whole batch shares a
    /// single resample prompt and a single "already on the disk" prompt.
    /// `release` (if provided) runs once every file has been read — used to
    /// drop security-scoped access for dropped files.
    private func importFiles(_ audioURLs: [URL], release: (() -> Void)? = nil) {
        NSLog("[IMPORT] ContentView.importFiles %d file(s)", audioURLs.count)
        guard !audioURLs.isEmpty else { release?(); return }
        let loFi = lowQualityImport
        DispatchQueue.global(qos: .userInitiated).async {
            defer { release?() }
            var clean: [[AudioImportPipeline.Channel]] = []
            var dupes: [[AudioImportPipeline.Channel]] = []
            var dupeFileNames: [String] = []
            let consent = AudioImportPipeline.ResampleConsent()   // ask once per batch

            // Decode + convert every file first, then sort into new vs. already-on-disk.
            for fileURL in audioURLs {
                let channels: [AudioImportPipeline.Channel]
                do {
                    channels = try AudioImportPipeline.process(
                        url: fileURL, loFi: loFi, stereo: .stereoLR,
                        names: diskImage, consent: consent)
                } catch AkaiError.cancelled {
                    return   // user declined the resample prompt — import nothing
                } catch {
                    // One file: say why it failed. A batch: skip it and carry on.
                    if audioURLs.count == 1 {
                        DispatchQueue.main.async { alertMessage = error.localizedDescription; showingAlert = true }
                    }
                    continue
                }
                guard let first = channels.first else { continue }
                let matches = diskImage.duplicateSampleNames(forPCM: first.pcm)
                NSLog("[IMPORT] ContentView dupe check %@ → names [%@] | PCM matches on disk: [%@]",
                      fileURL.lastPathComponent, channels.map(\.name).joined(separator: ", "),
                      matches.joined(separator: ", "))
                if matches.isEmpty {
                    clean.append(channels)
                } else {
                    dupes.append(channels)
                    dupeFileNames.append(fileURL.lastPathComponent)
                }
            }

            // Import non-duplicate files immediately.
            for channels in clean { addChannels(channels) }

            guard !dupes.isEmpty else { return }

            DispatchQueue.main.async {
                duplicateSampleCount = dupes.count
                duplicateSampleHasOtherFiles = !clean.isEmpty
                duplicateSampleMessage = AkaiDiskImage.duplicateImportMessage(dupeFileNames)
                pendingSampleImport = {
                    DispatchQueue.global(qos: .userInitiated).async {
                        for channels in dupes { addChannels(channels) }
                    }
                }
                duplicateSampleAlert = true
            }
        }
    }

    /// A dropped disk image loads here if this window is empty, otherwise it
    /// opens in its own window — it never replaces the image already shown.
    private func handleDroppedDisk(url: URL, release: @escaping () -> Void) {
        defer { release() }
        open(url)
    }
}
