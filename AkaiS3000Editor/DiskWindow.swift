import SwiftUI
import AppKit

// MARK: - One window per disk image
//
// Each window owns its own AkaiDiskImage. The pieces here replace the old
// single shared image:
//   • DiskWindowRequest — the value each window is opened with (a file to open,
//     or a blank image to create). SwiftUI uses it to de-duplicate windows
//     (opening a file that's already open brings its window to the front) and
//     to restore windows on relaunch. ContentView keeps it in sync with what
//     the window actually shows.
//   • DiskImageRegistry — weak list of the open images, for the quit check and
//     "is this file already open?".
//   • DiskWindowActions — File-menu actions published by the focused window,
//     replacing the old broadcast notifications (which every window received).
//   • DiskWindowCloseGuard — the "edited" dot on the close button, and a
//     Save / Don't Save / Cancel prompt when closing a window with changes.

enum DiskWindowRequest: Hashable, Codable {
    /// Open this image file.
    case open(URL)
    /// Ask for a location and create a blank image (unique so each request is a new window).
    case create(UUID)
    /// An empty window showing the start screen.
    case empty(UUID)
}

struct DiskWindow: View {
    static let groupID = "disk"

    @Binding var request: DiskWindowRequest?
    @ObservedObject var greaseweazle: GreaseweazleRunner
    @StateObject private var diskImage = AkaiDiskImage()

    var body: some View {
        ContentView(diskImage: diskImage, greaseweazle: greaseweazle, request: $request)
            .frame(minWidth: 1100, minHeight: 700)
    }

    /// The Open panel used by both the File menu and the start screen.
    static func chooseImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "img")!,
                                     .init(filenameExtension: "ima")!,
                                     .data]
        panel.title = "Open Akai S3000 Disk Image"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.standardizedFileURL }
    }
}

// MARK: - Registry of open images

final class DiskImageRegistry {
    static let shared = DiskImageRegistry()

    private final class WeakImage {
        weak var image: AkaiDiskImage?
        init(_ image: AkaiDiskImage) { self.image = image }
    }
    private var entries: [WeakImage] = []

    func register(_ image: AkaiDiskImage) {
        entries.removeAll { $0.image == nil }
        guard !entries.contains(where: { $0.image === image }) else { return }
        entries.append(WeakImage(image))
    }

    func unregister(_ image: AkaiDiskImage) {
        entries.removeAll { $0.image == nil || $0.image === image }
        windows[ObjectIdentifier(image)] = nil
    }

    var images: [AkaiDiskImage] { entries.compactMap { $0.image } }

    // Each image is shown in exactly one window. Key monitors use this to
    // ignore keystrokes meant for other windows (NSEvent local monitors see
    // every key event in the app, whichever window it's for).
    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var windows: [ObjectIdentifier: WeakWindow] = [:]

    func setWindow(_ window: NSWindow, for image: AkaiDiskImage) {
        windows[ObjectIdentifier(image)] = WeakWindow(window)
    }

    func window(for image: AkaiDiskImage) -> NSWindow? {
        windows[ObjectIdentifier(image)]?.window
    }

    /// The open image showing the file at `url`, if any.
    func image(openAt url: URL) -> AkaiDiskImage? {
        let target = url.standardizedFileURL
        return images.first { $0.isLoaded && $0.imageURL?.standardizedFileURL == target }
    }
}

// MARK: - File menu → focused window

struct DiskWindowActions {
    let newImage: () -> Void
    let openImage: () -> Void
    let importEmu: () -> Void
    let isLoaded: Bool
}

private struct DiskWindowActionsKey: FocusedValueKey {
    typealias Value = DiskWindowActions
}

extension FocusedValues {
    var diskWindowActions: DiskWindowActions? {
        get { self[DiskWindowActionsKey.self] }
        set { self[DiskWindowActionsKey.self] = newValue }
    }
}

/// File menu items. They act on the focused window; with no window open, New
/// and Open create a window for the result.
struct FileMenuButtons: View {
    @FocusedValue(\.diskWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Disk Image…") {
            if let actions {
                actions.newImage()
            } else {
                openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.create(UUID()))
            }
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Open Disk Image…") {
            if let actions {
                actions.openImage()
            } else {
                for url in DiskWindow.chooseImages() {
                    openWindow(id: DiskWindow.groupID, value: DiskWindowRequest.open(url))
                }
            }
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button {
            if let actions {
                actions.importEmu()
            } else {
                // No focused window — post notification so AkaiS3000EditorApp
                // can open a new window and then trigger the import.
                NotificationCenter.default.post(name: .importEmuDisks, object: nil)
            }
        } label: {
            Label("Import E-MU ESI Disk…", systemImage: "arrow.down.circle.fill")
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}

// MARK: - Unsaved changes

enum UnsavedChangesPrompt {
    /// Ask whether to save `image` before `action` ("closing", "quitting").
    /// Returns true if it's OK to go ahead (saved, nothing to save, or Don't Save).
    static func confirm(_ image: AkaiDiskImage, action: String) -> Bool {
        guard image.hasUnsavedChanges else { return true }
        let name = image.imageURL?.lastPathComponent ?? "this disk image"
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(name)” before \(action)?"
        alert.informativeText = "If you don't save, your changes to the disk image will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return save(image)
        case .alertSecondButtonReturn: return true
        default:                       return false
        }
    }

    /// Save, reporting any failure. Returns true on success.
    static func save(_ image: AkaiDiskImage) -> Bool {
        do {
            try image.saveImageToDisk()
            return true
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Couldn't save “\(image.imageURL?.lastPathComponent ?? "disk image")”"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .critical
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            return false
        }
    }
}

// MARK: - Window close guard

extension AkaiDiskImage {
    /// True if `event` is for this image's window. Every NSEvent local key
    /// monitor sees every key event in the app, so monitors call this first —
    /// otherwise Delete or Space in one window would also act in the others.
    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return window === DiskImageRegistry.shared.window(for: self)
    }
}

/// Attaches to the hosting NSWindow to show the "edited" dot in the close
/// button, to ask before closing a window with unsaved changes, and to record
/// which window shows which image (for ownsKeyEvent).
///
/// SwiftUI has no hook for vetoing a window close, so this slips a small
/// delegate in front of SwiftUI's own: it answers windowShouldClose and
/// forwards every other delegate call to the original.
struct DiskWindowCloseGuard: NSViewRepresentable {
    let diskImage: AkaiDiskImage
    let isEdited: Bool
    /// Window and tab title (the image's file name).
    let title: String
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        let edited = isEdited
        let image = diskImage
        let title = title
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
            DiskImageRegistry.shared.setWindow(window, for: image)
            window.isDocumentEdited = edited
            // Tabs are labelled from NSWindowTab, which SwiftUI's navigation
            // title doesn't reliably reach — set both directly.
            if window.title != title { window.title = title }
            if window.tab.title != title { window.tab.title = title }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool = { true }
        private weak var original: NSWindowDelegate?
        private var didPlace = false

        func attach(to window: NSWindow) {
            if !didPlace {
                didPlace = true
                // New disk images open as tabs of the existing window. Setting
                // tabbingMode alone is too late here (SwiftUI has already shown
                // the window), so join the tab group explicitly.
                window.tabbingIdentifier = Self.tabbingID
                window.tabbingMode = .preferred
                if !Self.joinTabGroup(window) {
                    Self.cascadeIfStacked(window)
                }
            }
            guard window.delegate !== self else { return }
            original = window.delegate
            window.delegate = self
        }

        private static let tabbingID = "AkaiDiskImageWindow"

        /// Add `window` as a tab of the frontmost other disk-image window.
        /// Returns false if there's no other window to join.
        private static func joinTabGroup(_ window: NSWindow) -> Bool {
            if let tabs = window.tabbedWindows, tabs.count > 1 { return true }  // already tabbed (system setting)
            guard let host = NSApp.orderedWindows.first(where: {
                $0 !== window && $0.isVisible && $0.tabbingIdentifier == tabbingID
            }) else { return false }
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            return true
        }

        /// SwiftUI opens each new window at the saved position, i.e. exactly on
        /// top of the previous one — which makes the older window look like it
        /// vanished. Only used when a window isn't joining a tab group (e.g. the
        /// tab was dragged out, or no other window exists): step it down/right
        /// until it isn't covering another.
        private static func cascadeIfStacked(_ window: NSWindow) {
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
            var topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            for _ in 0..<20 {
                let stacked = others.contains {
                    abs($0.frame.minX - topLeft.x) < 4 && abs($0.frame.maxY - topLeft.y) < 4
                }
                guard stacked else { break }
                topLeft = window.cascadeTopLeft(from: topLeft)
                if topLeft == NSPoint(x: window.frame.minX, y: window.frame.maxY) { break }
                window.setFrameTopLeftPoint(topLeft)
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
