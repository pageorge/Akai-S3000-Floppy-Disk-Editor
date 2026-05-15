import SwiftUI

struct ContentView: View {
    @StateObject private var diskImage = AkaiDiskImage()
    @State private var selectedTab: SidebarTab = .samples
    @State private var selectedSampleID: UUID? = nil
    @State private var selectedProgramID: UUID? = nil
    @State private var showingAlert = false
    @State private var alertMessage = ""

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
        .onReceive(NotificationCenter.default.publisher(for: .openDiskImage)) { _ in
            openDiskImage()
        }
        .alert("Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if diskImage.isLoaded {
                    Button {
                        openDiskImage()
                    } label: {
                        Label("Open", systemImage: "folder")
                    }

                    Button {
                        importWAV()
                    } label: {
                        Label("Import WAV", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a WAV file as a new sample")
                }
            }
        }
    }

    private func openDiskImage() {
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
            do {
                let newSample = try diskImage.importWAVAsSample(wavURL: url)
                DispatchQueue.main.async {
                    diskImage.samples.append(newSample)
                    selectedSampleID = newSample.id
                    selectedTab = .samples
                }
            } catch {
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }
}
