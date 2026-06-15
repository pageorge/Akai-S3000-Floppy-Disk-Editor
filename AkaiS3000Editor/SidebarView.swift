import SwiftUI

struct SidebarView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedTab: ContentView.SidebarTab
    @Binding var selectedSampleID: UUID?
    @Binding var selectedProgramID: UUID?

    @State private var sampleToDelete: AkaiSample? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteKeyMonitor: Any? = nil

    private var sampleToDeleteName: String {
        guard let s = sampleToDelete else { return "" }
        return s.header.name.isEmpty ? s.directoryEntry.name : s.header.name
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
                            isSelected: selectedSampleID == sample.id,
                            onTap: { selectedTab = .samples; selectedSampleID = sample.id },
                            onDelete: { sampleToDelete = sample; showDeleteConfirm = true }
                        )
                    }
                } header: {
                    Label("Samples (\(diskImage.samples.count))", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture { selectedTab = .samples; selectedSampleID = nil }
                }

                Section {
                    ForEach(diskImage.programs) { prog in
                        SidebarProgramRow(
                            program: prog,
                            isSelected: selectedProgramID == prog.id,
                            onTap: { selectedTab = .programs; selectedProgramID = prog.id }
                        )
                    }
                } header: {
                    Label("Programs (\(diskImage.programs.count))", systemImage: "pianokeys")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture { selectedTab = .programs; selectedProgramID = nil }
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
                if (event.keyCode == 51 || event.keyCode == 117),
                   let id = self.selectedSampleID,
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
            Button("Cancel", role: .cancel) { sampleToDelete = nil }
        } message: {
            Text("This removes the sample from the list. The disk image file is not modified until you save.")
        }
    }
}

struct SidebarSampleRow: View {
    let sample: AkaiSample
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

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
            Button(role: .destructive, action: onDelete) {
                Label("Delete \"\(displayName)\"", systemImage: "trash")
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
    }
}
