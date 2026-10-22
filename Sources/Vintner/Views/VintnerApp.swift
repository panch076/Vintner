import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDirectories()
        DispatchQueue.global(qos: .background).async { Paths.pruneOldLogs() }
    }

    /// Finder "Open With…" / double-clicking an .exe associated with Vintner.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpen { onOpen(urls) } else { pending += urls }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        onOpen = handler
        if !pending.isEmpty { handler(pending); pending = [] }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct VintnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var runtime = RuntimeManager()
    @StateObject private var store = BottleStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(runtime)
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { delegate.attach { [weak model] urls in model?.open(urls) } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { model.showNewBottle = true }
                    .keyboardShortcut("n")
                    .disabled(!runtime.isReady)
                Button("Run Windows Program…") { chooseAndRun() }
                    .keyboardShortcut("o")
                    .disabled(!runtime.isReady)
            }
        }
    }

    private func chooseAndRun() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["exe", "msi", "bat", "lnk", "com"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { model.open(panel.urls) }
    }
}
