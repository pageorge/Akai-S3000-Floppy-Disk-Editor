import Foundation
import Combine

/// Runs the external Greaseweazle command-line tool (`gw`) to read/write real
/// floppy disks, streaming its output into a log and tracking progress.
///
/// The app sandbox must be disabled for this to launch an external process.
@MainActor
final class GreaseweazleRunner: ObservableObject {

    enum Drive: String, CaseIterable, Identifiable {
        case a = "A"
        case b = "B"
        var id: String { rawValue }
        var label: String { "Drive \(rawValue)" }
    }

    /// Greaseweazle disk format. Raw value is the exact --format string passed to gw.
    enum DiskFormat: String, CaseIterable, Identifiable {
        case akai1600 = "akai.1600"
        case akai800  = "akai.800"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .akai1600: return "akai.1600 (Akai S3000 HD)"
            case .akai800:  return "akai.800 (Akai S1000 DD)"
            }
        }
    }

    enum Activity: Equatable {
        case idle
        case reading
        case writing
    }

    @Published var drive: Drive {
        didSet { UserDefaults.standard.set(drive.rawValue, forKey: Self.driveKey) }
    }
    @Published var format: DiskFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: Self.formatKey) }
    }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var logLines: [String] = []
    /// The .img file being read or written, shown with full path in the log view.
    @Published private(set) var currentFileURL: URL? = nil
    /// 0...1 when a percentage can be parsed from gw output, else nil (indeterminate).
    @Published private(set) var progress: Double? = nil

    private var process: Process?
    private static let driveKey  = "greaseweazle.drive"
    private static let formatKey = "greaseweazle.format"

    /// Called on the main actor with the output URL when a READ completes
    /// successfully (exit 0), so the app can auto-load the freshly read image.
    var onReadComplete: ((URL) -> Void)?

    /// Candidate install locations for the gw binary. ~/.local/bin (pipx/pip --user)
    /// is resolved against the real home directory. Homebrew Intel/ARM also covered.
    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/gw",
            "/opt/homebrew/bin/gw",
            "/usr/local/bin/gw",
            "\(home)/.local/bin/greaseweazle",
            "/opt/homebrew/bin/greaseweazle",
            "/usr/local/bin/greaseweazle"
        ]
    }

    var isBusy: Bool { activity != .idle }

    init() {
        let savedDrive = UserDefaults.standard.string(forKey: Self.driveKey)
        self.drive = Drive(rawValue: savedDrive ?? "A") ?? .a
        let savedFormat = UserDefaults.standard.string(forKey: Self.formatKey)
        self.format = DiskFormat(rawValue: savedFormat ?? "akai.1600") ?? .akai1600
    }

    /// Locate the gw binary, preferring known install locations.
    private func resolveBinary() -> String? {
        for path in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func clearLog() { logLines.removeAll(); progress = nil }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if let pct = Self.parsePercent(trimmed) {
            progress = pct
        } else if let frac = Self.parseCylinderFraction(trimmed) {
            progress = frac
        }
    }

    /// Read a physical floppy into `url` (.img).
    /// Mirrors: gw read --format=akai.1600 <file> --drive=B
    func read(to url: URL) {
        currentFileURL = url
        run(arguments: ["read",
                        "--format=\(format.rawValue)",
                        url.path,
                        "--drive=\(drive.rawValue)"],
            activity: .reading,
            startMessage: "Reading \(drive.label) -> \(url.lastPathComponent)")
    }

    /// Write an .img at `url` to a physical floppy.
    /// Mirrors: gw write --format=akai.1600 <file> --drive=B
    func write(from url: URL) {
        currentFileURL = url
        run(arguments: ["write",
                        "--format=\(format.rawValue)",
                        url.path,
                        "--drive=\(drive.rawValue)"],
            activity: .writing,
            startMessage: "Writing \(url.lastPathComponent) -> \(drive.label)")
    }

    func cancel() {
        process?.terminate()
        appendLog("- cancelled -")
    }

    private func run(arguments: [String], activity: Activity, startMessage: String) {
        guard !isBusy else { return }
        guard let binary = resolveBinary() else {
            appendLog("ERROR: gw not found. Checked ~/.local/bin, /opt/homebrew/bin, /usr/local/bin. Run 'which gw' in Terminal and tell me the path.")
            return
        }

        clearLog()
        self.activity = activity
        appendLog(startMessage)
        appendLog("$ \(binary) \(arguments.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            Task { @MainActor in
                for line in lines { self.appendLog(String(line)) }
            }
        }

        proc.terminationHandler = { p in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                let ok = p.terminationStatus == 0
                self.appendLog(ok ? "Done (exit 0)" : "Failed (exit \(p.terminationStatus))")
                if ok { self.progress = 1.0 }
                // Auto-load a freshly read image.
                if ok, activity == .reading, let url = self.currentFileURL {
                    self.onReadComplete?(url)
                }
                self.activity = .idle
                self.process = nil
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            appendLog("ERROR launching gw: \(error.localizedDescription)")
            self.activity = .idle
        }
    }

    // MARK: - Output parsing

    private static func parsePercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let digits = line[r].dropLast()
        guard let v = Double(digits) else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    private static func parseCylinderFraction(_ line: String) -> Double? {
        guard let r = line.range(of: #"(?:cylinder |T)(\d{1,3})"#, options: .regularExpression) else { return nil }
        let match = String(line[r])
        let num = match.filter { $0.isNumber }
        guard let cyl = Double(num) else { return nil }
        return min(max(cyl / 80.0, 0), 1)
    }
}
