#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `Vintner --snapshot <dir>` renders the main screens to PNGs offscreen
/// (no Screen Recording permission needed) for checking layouts.
@MainActor
enum Snapshot {
    static func run(into dir: URL) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        let runtime = RuntimeManager()
        let store = BottleStore()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func render<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 1000, height: 680)) {
            let root = view
                .environmentObject(model).environmentObject(runtime).environmentObject(store)
                .frame(width: size.width, height: size.height)
                .background(Color(NSColor.windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // let .onAppear/.task settle
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }

        if let bottle = store.bottles.first {
            model.selection = .bottle(bottle.url)
            render("1-main", ContentView())
            render("2-settings", BottleSettingsView(bottle: bottle), size: CGSize(width: 700, height: 1400))
            render("3-winetricks", WinetricksView(bottle: bottle))
            render("4-tools", ToolsView(bottle: bottle), size: CGSize(width: 700, height: 900))
        }
        render("5-runtime", RuntimeView())
        render("6-system", SystemView())
        render("7-setup", SetupView())
        render("8-newbottle", NewBottleSheet(), size: CGSize(width: 480, height: 330))
        exit(0)
    }
}
#endif
