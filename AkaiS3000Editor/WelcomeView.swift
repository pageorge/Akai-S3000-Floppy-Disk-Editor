import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 32) {
                AkaiLogoView()
                    .frame(width: 420, height: 120)
                VStack(spacing: 4) {
                    Text("Read, edit, and export samples and programs")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("from Akai S3000 .img disk images")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isDragging ? Color.red.opacity(0.08) : Color.secondary.opacity(0.06))
                        .frame(width: 380, height: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(
                                    isDragging ? Color.red.opacity(0.6) : Color.secondary.opacity(0.2),
                                    style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [6])
                                )
                        )
                    VStack(spacing: 6) {
                        Button {
                            NotificationCenter.default.post(name: .openDiskImage, object: nil)
                        } label: {
                            Label("Open Disk Image...", systemImage: "folder")
                                .frame(width: 180)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        Text("or drag a .img file here")
                            .font(.caption).foregroundStyle(.tertiary)
                        Button {
                            NotificationCenter.default.post(name: .createDiskImage, object: nil)
                        } label: {
                            Label("New Disk Image", systemImage: "plus.rectangle.on.folder")
                                .frame(width: 180)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isDragging)
                HStack(spacing: 28) {
                    FeaturePill(icon: "waveform",              text: "Read Samples")
                    FeaturePill(icon: "square.and.arrow.up",   text: "Export WAV")
                    FeaturePill(icon: "square.and.arrow.down", text: "Import WAV")
                    FeaturePill(icon: "pianokeys",             text: "Edit Keymaps")
                }
            }
            .padding(60)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                // Must start security-scoped access so we can write back to the file later
                let accessing = url.startAccessingSecurityScopedResource()
                DispatchQueue.main.async {
                    try? diskImage.load(from: url)
                    if !accessing { _ = url.startAccessingSecurityScopedResource() }
                }
            }
            return true
        }
    }
}

// MARK: - Logo

struct AkaiLogoView: View {
    let akaiRed = Color(red: 0.91, green: 0, blue: 0.11)

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.07))
            VStack {
                Rectangle().fill(akaiRed).frame(height: 5)
                Spacer()
                Rectangle().fill(akaiRed).frame(height: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                FloppyIconView()
                    .frame(width: 52, height: 60)
                    .padding(.leading, 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AKAI")
                        .font(.system(size: 54, weight: .black))
                        .kerning(-1)
                        .foregroundColor(.white)
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        Text("S3000")
                            .font(.system(size: 28, weight: .black))
                            .foregroundColor(akaiRed)
                        Text("EDITOR")
                            .font(.system(size: 14, weight: .bold))
                            .kerning(4)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Spacer()
                WaveformLogoView()
                    .frame(width: 70, height: 60)
                    .padding(.trailing, 18)
            }
        }
    }
}

struct FloppyIconView: View {
    let red = Color(red: 0.91, green: 0, blue: 0.11)
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4), with: .color(red))
            ctx.fill(Path(roundedRect: CGRect(x: 4, y: 4, width: w-8, height: h*0.42), cornerRadius: 2), with: .color(.black.opacity(0.85)))
            var wave = Path()
            let pts: [(CGFloat,CGFloat)] = [(6,18),(10,12),(14,22),(18,14),(22,20),(26,10),(30,19),(34,14),(38,18),(42,18)]
            wave.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for p in pts.dropFirst() { wave.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.stroke(wave, with: .color(red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(roundedRect: CGRect(x: 12, y: h*0.58, width: w-24, height: 5), cornerRadius: 2), with: .color(.black.opacity(0.8)))
            ctx.fill(Path(roundedRect: CGRect(x: w-14, y: h*0.76, width: 10, height: 10), cornerRadius: 2), with: .color(.black.opacity(0.8)))
            ctx.fill(Path(ellipseIn: CGRect(x: w/2-6, y: h*0.72, width: 12, height: 12)), with: .color(.black.opacity(0.8)))
            ctx.fill(Path(ellipseIn: CGRect(x: w/2-2.5, y: h*0.725, width: 5, height: 5)), with: .color(red))
        }
    }
}

struct WaveformLogoView: View {
    let red = Color(red: 0.91, green: 0, blue: 0.11)
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let pts1: [(CGFloat,CGFloat)] = [(0,h*0.7),(8,h*0.4),(16,h*0.8),(24,h*0.2),(32,h*0.6),(40,h*0.05),(48,h*0.5),(56,h*0.3),(64,h*0.6),(w,h*0.5)]
            var p1 = Path()
            p1.move(to: CGPoint(x: pts1[0].0, y: pts1[0].1))
            for p in pts1.dropFirst() { p1.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.stroke(p1, with: .color(red.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let pts2: [(CGFloat,CGFloat)] = [(0,h*0.7),(8,h*0.55),(16,h*0.75),(24,h*0.45),(32,h*0.68),(40,h*0.38),(48,h*0.62),(56,h*0.5),(64,h*0.65),(w,h*0.6)]
            var p2 = Path()
            p2.move(to: CGPoint(x: pts2[0].0, y: pts2[0].1))
            for p in pts2.dropFirst() { p2.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.stroke(p2, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Feature pill

struct FeaturePill: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color(red: 0.91, green: 0, blue: 0.11))
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
