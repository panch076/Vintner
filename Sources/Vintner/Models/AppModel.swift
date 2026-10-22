import AppKit
import Foundation

enum SidebarItem: Hashable {
    case bottle(URL)
    case runtime
    case system
}

@MainActor
final class BottleStore: ObservableObject {
    @Published private(set) var bottles: [Bottle] = []

    init() { reload() }

    func reload() {
        Paths.ensureDirectories()
        let existing = Dictionary(bottles.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.bottles, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        bottles = dirs.compactMap { dir in
            if let bottle = existing[dir] { return bottle }
            guard let meta = BottleMetadata.load(from: dir) else { return nil }
            return Bottle(url: dir, meta: meta)
        }
        .sorted { $0.meta.name.localizedStandardCompare($1.meta.name) == .orderedAscending }
    }

    func bottle(for url: URL) -> Bottle? { bottles.first { $0.url == url } }

    func create(name: String, settings: BottleSettings) async -> Bottle? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = BottleMetadata(name: cleaned.isEmpty ? "Bottle" : cleaned, settings: settings)
        let folderName = meta.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            + "-" + meta.id.uuidString.prefix(6)
        let url = Paths.bottles.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try meta.write(to: url)
        } catch {
            return nil
        }
        let bottle = Bottle(url: url, meta: meta)
        bottle.busyStatus = "Creating Windows environment… (first time takes about a minute)"
        bottles.append(bottle)
        bottles.sort { $0.meta.name.localizedStandardCompare($1.meta.name) == .orderedAscending }

        let logURL = Paths.logs.appendingPathComponent("create-\(folderName).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        defer { try? log?.close() }
        do {
            try await Wine.createPrefix(bottleURL: url, settings: settings, log: log)
            bottle.busyStatus = nil
            bottle.rescanPrograms()
        } catch {
            bottle.busyStatus = nil
            bottle.lastError = "\(error.localizedDescription) See \(logURL.path)"
        }
        return bottle
    }

    /// Moves the bottle to the Trash (recoverable) after stopping its processes.
    func delete(_ bottle: Bottle) async {
        await bottle.killAll()
        do {
            try FileManager.default.trashItem(at: bottle.url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: bottle.url)
        }
        bottles.removeAll { $0.url == bottle.url }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem?
    @Published var filesToOpen: [URL] = []
    @Published var showNewBottle = false
    @Published var alert: String?

    @Published var lastBottleURL: URL? {
        didSet { UserDefaults.standard.set(lastBottleURL?.path, forKey: "lastBottle") }
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: "lastBottle") { lastBottleURL = URL(fileURLWithPath: path) }
    }

    func open(_ urls: [URL]) {
        let runnable = urls.filter { ["exe", "msi", "bat", "lnk", "com"].contains($0.pathExtension.lowercased()) }
        guard !runnable.isEmpty else { return }
        filesToOpen = runnable
    }
}

/// Wraps a winetricks run, streaming its log file into the UI. (A pipe can't be used: wineserver
/// inherits it and holds it open after winetricks exits.)
@MainActor
final class WinetricksRun: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?

    private var timer: Timer?
    private var offset: UInt64 = 0
    private var logURL: URL?

    func start(verbs: [String], bottle: Bottle) {
        guard !isRunning, !verbs.isEmpty else { return }
        output = "$ winetricks --unattended \(verbs.joined(separator: " "))\n"
        exitCode = nil
        isRunning = true
        offset = 0
        let log = Paths.logs.appendingPathComponent("winetricks-\(UUID().uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logURL = log
        let handle = try? FileHandle(forWritingTo: log)

        var env = Wine.environment(bottleURL: bottle.url, settings: bottle.meta.settings)
        env["WINE"] = Paths.wineBin.path
        env["WINESERVER"] = Paths.wineserverBin.path
        env["W_OPT_UNATTENDED"] = "1"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        env["XDG_CACHE_HOME"] = Paths.cache.path
        env["WINEDEBUG"] = "-all"

        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        let bottleURL = bottle.url
        Task {
            let status = (try? await Shell.run(Paths.winetricks, ["--unattended"] + verbs,
                                               environment: env, currentDirectory: bottleURL, output: handle)) ?? -1
            try? handle?.close()
            await Wine.wineserver(["-w"], bottleURL: bottleURL)
            self.poll()
            self.timer?.invalidate()
            self.timer = nil
            self.exitCode = status
            self.isRunning = false
            self.output += status == 0 ? "\n✓ Finished successfully.\n" : "\n✗ winetricks exited with code \(status).\n"
            bottle.rescanPrograms()
        }
    }

    private func poll() {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        output += String(decoding: data, as: UTF8.self)
        if output.count > 400_000 { output = String(output.suffix(300_000)) } // keep the view responsive
    }
}
