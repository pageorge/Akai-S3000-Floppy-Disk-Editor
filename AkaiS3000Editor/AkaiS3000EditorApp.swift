import SwiftUI
import AppKit

@main
struct AkaiS3000EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// One runner for the whole app — there's only one Greaseweazle. The window
    /// that starts a read/write claims it (see ContentView.claimGreaseweazle).
    @StateObject private var greaseweazle = GreaseweazleRunner()

    var body: some Scene {
        WindowGroup(id: DiskWindow.groupID, for: DiskWindowRequest.self) { $request in
            DiskWindow(request: $request, greaseweazle: greaseweazle)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                FileMenuButtons()
            }
        }
    }
}

extension Notification.Name {
    static let openDiskImage = Notification.Name("openDiskImage")
    static let createDiskImage = Notification.Name("createDiskImage")
    static let beginMultiRename = Notification.Name("beginMultiRename")
    static let openLastSession = Notification.Name("openLastSession")
    static let importEmuDisks = Notification.Name("importEmuDisks")
}

// MARK: - App Delegate
// Intercepts Cmd+Q / Quit so the user gets a chance to save unsaved changes in
// every open window before the disk image data is lost. (Closing a single
// window is handled by DiskWindowCloseGuard.)
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = DiskImageRegistry.shared.images.filter { $0.hasUnsavedChanges }
        guard !dirty.isEmpty else { return .terminateNow }

        if dirty.count == 1 {
            return UnsavedChangesPrompt.confirm(dirty[0], action: "quitting") ? .terminateNow : .terminateCancel
        }

        let names = dirty.map { "• " + ($0.imageURL?.lastPathComponent ?? "Untitled") }
        let alert = NSAlert()
        alert.messageText = "\(dirty.count) disk images have unsaved changes"
        alert.informativeText = names.joined(separator: "\n") + "\n\nIf you quit without saving, these changes will be lost."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for image in dirty where !UnsavedChangesPrompt.save(image) {
                return .terminateCancel
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
