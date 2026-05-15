import SwiftUI

@main
struct AkaiS3000EditorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
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
}
