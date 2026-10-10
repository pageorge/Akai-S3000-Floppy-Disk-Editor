import SwiftUI
import AppKit

/// "Import E-mu ESI Disks…" sheet: pick a floppy set (or a .esi/.e3x bank
/// file), tick the presets to bring across, check they fit, import.
struct EmuImportSheet: View {
    @ObservedObject var diskImage: AkaiDiskImage
    /// Bank already parsed by the menu action — skip the Choose Disks flow.
    var preloadedBank: EmuBank? = nil
    /// Called with a one-line summary after a successful import.
    var onImported: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("lowQualityImport") private var lowQualityImport = false

    @State private var bank: EmuBank?
    @State private var selected: Set<Int> = []
    @State private var options = EmuImportOptions()
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var selectedPresets: [EmuPreset] {
        bank?.presets.filter { selected.contains($0.id) } ?? []
    }
    private var neededBlocks: Int {
        guard let bank else { return 0 }
        return EmuToAkai.estimatedBlocks(selectedPresets, bank: bank, options: options)
    }
    private var freeBlocks: Int { diskImage.freeBlockCount }
    private var fits: Bool { neededBlocks <= freeBlocks }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import E-mu ESI Disks").font(.title2.bold())
                Spacer()
                Button(bank == nil ? "Choose Disks…" : "Choose Other Disks…") { chooseFiles() }
                    .disabled(isWorking)
            }

            if let bank {
                bankHeader(bank)
                presetList(bank)
                optionsSection
                spaceBar
            } else {
                emptyState
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(importButtonTitle) { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bank == nil || selected.isEmpty || !fits || isWorking)
            }
        }
        .padding(20)
        .frame(width: 600, height: 620)
        .onAppear {
            options.downsampleTo22k = lowQualityImport
            if let preloadedBank {
                bank = preloadedBank
                selected = Set(preloadedBank.presets.map(\.id))
            }
        }
    }

    private var importButtonTitle: String {
        let n = selected.count
        return n == 0 ? "Import" : "Import \(n) Preset\(n == 1 ? "" : "s")"
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "opticaldiscdrive").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Choose the disk images of an ESI-32 / ESI-2000 / ESI-4000 or Emulator IIIX floppy set (1.44 MB .img files), or a single .esi / .e3x bank file.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("You can pick just disk 1 — the other disks of the set are found automatically if they're in the same folder.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bankHeader(_ bank: EmuBank) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bank.name.isEmpty ? "Untitled bank" : bank.name).font(.headline)
            Text("\(bank.variant.rawValue) · \(bank.diskCount > 0 ? "\(bank.diskCount) disk\(bank.diskCount == 1 ? "" : "s")" : "bank file") · \(bank.presets.count) presets · \(bank.samples.count) samples")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(bank.warnings, id: \.self) { w in
                Text(w).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func presetList(_ bank: EmuBank) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Presets").font(.subheadline.bold())
                Spacer()
                Button("All") { selected = Set(bank.presets.map(\.id)) }
                Button("None") { selected = [] }
            }
            .buttonStyle(.link)

            List(bank.presets) { preset in
                Toggle(isOn: binding(for: preset.id)) {
                    HStack {
                        Text(preset.name.isEmpty ? "Preset \(preset.id + 1)" : preset.name)
                        Spacer()
                        Text(presetDetail(preset, bank: bank))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Downsample to 22.05 kHz (halves the space needed)", isOn: $options.downsampleTo22k)
            Toggle("Import secondary layer as velocity-split keygroups", isOn: $options.includeSecondaryLayer)
            Toggle("Convert amp envelopes (approximate)", isOn: $options.convertEnvelopes)
        }
        .toggleStyle(.checkbox)
    }

    private var spaceBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(min(neededBlocks, max(freeBlocks, 1))),
                         total: Double(max(freeBlocks, 1)))
                .tint(fits ? .accentColor : .red)
            Text("Needs \(neededBlocks) KB of \(freeBlocks) KB free on this disk")
                .font(.caption)
                .foregroundStyle(fits ? Color.secondary : Color.red)
        }
    }

    // MARK: Helpers

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in if on { selected.insert(id) } else { selected.remove(id) } })
    }

    private func presetDetail(_ p: EmuPreset, bank: EmuBank) -> String {
        let kg = EmuToAkai.keygroupCount(p, options: options)
        let samples = p.sampleNumbers(includeSecondary: options.includeSecondaryLayer)
        let kb = EmuToAkai.estimatedBlocks([p], bank: bank, options: options)
        return "\(kg) kg · \(samples.count) smp · \(kb) KB"
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.title = "Choose E-mu ESI Disk Images or Bank File"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        errorMessage = nil
        do {
            let loaded = try EmuESIParser.load(urls: panel.urls)
            bank = loaded
            selected = []
            if loaded.presets.isEmpty { errorMessage = "This bank contains no presets." }
        } catch {
            bank = nil
            errorMessage = error.localizedDescription
        }
    }

    private func runImport() {
        guard let bank else { return }
        isWorking = true
        errorMessage = nil
        let presets = selectedPresets
        // Let the progress indicator draw before the (main-thread) import runs.
        DispatchQueue.main.async {
            defer { isWorking = false }
            do {
                let summary = try diskImage.importEmuPresets(presets, from: bank, options: options)
                onImported(summary.message)
                if summary.warnings.isEmpty {
                    dismiss()
                } else {
                    errorMessage = summary.message + ":\n• " + summary.warnings.joined(separator: "\n• ")
                    self.bank = nil   // already imported — avoid a double import
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
