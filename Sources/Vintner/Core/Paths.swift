import Foundation

/// All on-disk locations used by Vintner. Everything lives in the user's Library so the
/// app bundle itself stays read-only (and its code signature intact).
enum Paths {
    private static let fm = FileManager.default
    private static let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]

    static let appSupport = library.appendingPathComponent("Application Support/Vintner", isDirectory: true)
    static let runtime = appSupport.appendingPathComponent("Runtime", isDirectory: true)
    static let bottles = appSupport.appendingPathComponent("Bottles", isDirectory: true)
    static let logs = library.appendingPathComponent("Logs/Vintner", isDirectory: true)
    static let cache = library.appendingPathComponent("Caches/Vintner", isDirectory: true)
    static let downloads = cache.appendingPathComponent("Downloads", isDirectory: true)
    static let launchers = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Vintner", isDirectory: true)

    static let wineRoot = runtime.appendingPathComponent("wine", isDirectory: true)
    static let wineBin = wineRoot.appendingPathComponent("bin/wine")
    static let wineserverBin = wineRoot.appendingPathComponent("bin/wineserver")
    static let dxvk = runtime.appendingPathComponent("dxvk", isDirectory: true)
    static let toolsBin = runtime.appendingPathComponent("bin", isDirectory: true)
    static let winetricks = toolsBin.appendingPathComponent("winetricks")
    static let cabextract = toolsBin.appendingPathComponent("cabextract")
    static let installedManifest = runtime.appendingPathComponent("installed.json")

    /// Archives shipped inside the app bundle by `build.sh --embed-runtime` (offline installs).
    static var payload: URL? { Bundle.main.resourceURL?.appendingPathComponent("Payload", isDirectory: true) }

    static func ensureDirectories() {
        for dir in [appSupport, runtime, bottles, logs, cache, downloads, toolsBin] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Removes log files older than a week so ~/Library/Logs doesn't grow without bound.
    static func pruneOldLogs(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let files = try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
