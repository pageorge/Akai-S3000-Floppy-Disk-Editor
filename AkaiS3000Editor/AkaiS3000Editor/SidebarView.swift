import SwiftUI

struct SidebarView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @Binding var selectedTab: ContentView.SidebarTab
    @Binding var selectedSampleID: UUID?
    @Binding var selectedProgramID: UUID?

    var body: some View {
        List(selection: $selectedTab) {
            if diskImage.isLoaded {
                // Disk name header
                Section {
                    EmptyView()
                } header: {
                    HStack {
                        Image(systemName: "internaldrive.fill")
                            .foregroundStyle(.blue)
                        Text(diskImage.diskName.isEmpty ? "Akai Disk" : diskImage.diskName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }

                // Samples section
                Section {
                    ForEach(diskImage.samples) { sample in
                        SidebarSampleRow(sample: sample)
                            .tag(sample.id)
                            .onTapGesture {
                                selectedTab = .samples
                                selectedSampleID = sample.id
                            }
                    }
                } header: {
                    Label("Samples (\(diskImage.samples.count))", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            selectedTab = .samples
                            selectedSampleID = nil
                        }
                }

                // Programs section
                Section {
                    ForEach(diskImage.programs) { prog in
                        SidebarProgramRow(program: prog)
                            .tag(prog.id)
                            .onTapGesture {
                                selectedTab = .programs
                                selectedProgramID = prog.id
                            }
                    }
                } header: {
                    Label("Programs (\(diskImage.programs.count))", systemImage: "pianokeys")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            selectedTab = .programs
                            selectedProgramID = nil
                        }
                }

                // Disk info
                Section {
                    Label("Disk Info", systemImage: "info.circle")
                        .onTapGesture { selectedTab = .diskInfo }
                }
            } else {
                // Not loaded state
                VStack(alignment: .leading, spacing: 8) {
                    Label("No Disk Loaded", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("Open a .img file to begin")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("S3000 Editor")
    }
}

struct SidebarSampleRow: View {
    let sample: AkaiSample

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .foregroundStyle(.blue)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(sample.header.name.isEmpty ? sample.directoryEntry.name : sample.header.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text("\(sample.header.sampleRate / 1000)kHz · \(midiNoteName(sample.header.midiRootNote))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(note) / 12 - 1
        let name = names[Int(note) % 12]
        return "\(name)\(octave)"
    }
}

struct SidebarProgramRow: View {
    let program: AkaiProgramFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pianokeys.inverse")
                .foregroundStyle(.purple)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(program.program.name.isEmpty ? program.directoryEntry.name : program.program.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text("\(program.program.keyzones.count) keyzone\(program.program.keyzones.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
