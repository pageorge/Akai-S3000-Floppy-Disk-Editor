import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var isDragging = false

    var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(.background)

            VStack(spacing: 32) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(isDragging ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08))
                        .frame(width: 120, height: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(isDragging ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.2),
                                        lineWidth: isDragging ? 2 : 1)
                        )
                    Image(systemName: "internaldrive")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(isDragging ? .blue : .secondary)
                }
                .animation(.easeInOut(duration: 0.15), value: isDragging)

                VStack(spacing: 8) {
                    Text("Akai S3000 Editor")
                        .font(.title.bold())
                    Text("Read, edit, and export samples and programs\nfrom Akai S3000 .img disk images")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button {
                        NotificationCenter.default.post(name: .openDiskImage, object: nil)
                    } label: {
                        Label("Open Disk Image…", systemImage: "folder")
                            .frame(width: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("or drag a .img file here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Feature list
                HStack(spacing: 32) {
                    FeaturePill(icon: "waveform", text: "Read Samples")
                    FeaturePill(icon: "square.and.arrow.up", text: "Export WAV")
                    FeaturePill(icon: "square.and.arrow.down", text: "Import WAV")
                    FeaturePill(icon: "pianokeys", text: "Edit Keymaps")
                }
            }
            .padding(60)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    try? diskImage.load(from: url)
                }
            }
            return true
        }
    }
}

struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
