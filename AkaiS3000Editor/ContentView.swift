import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var selectedTab: SidebarTab = .samples
    @State private var selectedSampleID: UUID? = nil
    @State private var selectedProgramID: UUID? = nil
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @State private var toast: ToastData?
    @State private var pendingOpenAction: (() -> Void)? = nil
    @State private var showingUnsavedChangesConfirm = false

    enum SidebarTab: String, CaseIterable {
        case samples = "Samples"
        case programs = "Programs"
        case diskInfo = "Disk Info"

        var icon: String {
            switch self {
            case .samples: return "waveform"
            case .programs: return "pianokeys"
            case .diskInfo: return "internaldrive"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            SidebarView(
                diskImage: diskImage,
                selectedTab: $selectedTab,
                selectedSampleID: $selectedSampleID,
                selectedProgramID: $selectedProgramID
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if !diskImage.isLoaded {
                WelcomeView(diskImage: diskImage)
            } else {
                switch selectedTab {
                case .samples:
                    if let id = selectedSampleID,
                       let sample = diskImage.samples.first(where: { $0.id == id }) {
                        SampleDetailView(sample: sample, diskImage: diskImage)
                    } else {
                        SampleListView(diskImage: diskImage, selectedSampleID: $selectedSampleID)
                    }
                case .programs:
                    if let id = selectedProgramID,
                       let prog = diskImage.programs.first(where: { $0.id == id }) {
                        ProgramDetailView(programFile: prog, diskImage: diskImage)
                    } else {
                        ProgramListView(diskImage: diskImage, selectedProgramID: $selectedProgramID)
                    }
                case .diskInfo:
                    DiskInfoView(diskImage: diskImage)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiskImage)) { _ in
            openDiskImage()
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .toast($toast)
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if diskImage.isLoaded {
                    Button {
                        openDiskImage()
                    } label: {
                        Label("Open", systemImage: "folder")
                    }
                    .help("Open a disk image (.img) file")

                    Button {
                        importWAV()
                    } label: {
                        Label("Import WAV", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a WAV file as a new sample")

                    Button {
                        saveAll()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down.fill")
                    }
                    .help("Save all changes to disk image")
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
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
                selectedSampleID = nil
                selectedProgramID = nil
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }

    private func importWAV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Import WAV as Sample"

        if panel.runModal() == .OK, let url = panel.url {
            importSample(from: url)
        }
    }

    /// Import a single audio file at `url` as a new sample in the loaded disk.
    /// `release` (if provided) is called once the file read completes — used to
    /// drop security-scoped access for dropped files.
    private func importSample(from url: URL, release: (() -> Void)? = nil) {
        defer { release?() }
        do {
            let newSample = try diskImage.importAndAddSample(from: url)
            DispatchQueue.main.async {
                selectedSampleID = newSample.id
                selectedTab = .samples
            }
        } catch {
            DispatchQueue.main.async {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
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

                if diskExts.contains(ext) {
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

    private func handleDroppedDisk(url: URL, release: @escaping () -> Void) {
        let openIt = {
            defer { release() }
            do {
                try diskImage.load(from: url)
                selectedSampleID = nil
                selectedProgramID = nil
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
