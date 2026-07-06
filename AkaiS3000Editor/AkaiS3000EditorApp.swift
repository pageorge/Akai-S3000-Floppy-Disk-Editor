import SwiftUI
import AppKit

@main
struct AkaiS3000EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var diskImage = AppDiskImageHolder.shared
    @StateObject private var greaseweazle = GreaseweazleRunner()

    var body: some Scene {
        WindowGroup {
            ContentView(diskImage: diskImage.image, greaseweazle: greaseweazle)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Disk Image…") {
                    NotificationCenter.default.post(name: .createDiskImage, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Disk Image…") {
                    NotificationCenter.default.post(name: .openDiskImage, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openDiskImage = Notification.Name("openDiskImage")
    static let createDiskImage = Notification.Name("createDiskImage")
    static let beginMultiRename = Notification.Name("beginMultiRename")
}

// MARK: - Shared disk image holder
// The app delegate needs to see the same AkaiDiskImage instance that ContentView
// uses, so it can check hasUnsavedChanges when the app is asked to quit.
final class AppDiskImageHolder: ObservableObject {
    static let shared = AppDiskImageHolder()
    let image = AkaiDiskImage()
}

// MARK: - App Delegate
// Intercepts Cmd+Q / Quit so the user gets a chance to save unsaved changes
// (sample/program edits, deletions) before the disk image data is lost.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let diskImage = AppDiskImageHolder.shared.image
        guard diskImage.hasUnsavedChanges else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "If you quit now, your changes to the disk image will be lost. Do you want to save before quitting?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            do {
                try diskImage.saveImageToDisk()
                return .terminateNow
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Couldn't save changes"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.alertStyle = .critical
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
                return .terminateCancel
            }
        case .alertSecondButtonReturn: // Don't Save
            return .terminateNow
        default: // Cancel
            return .terminateCancel
        }
    }
}
