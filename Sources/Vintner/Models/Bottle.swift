import AppKit
import Foundation

struct ProgramEntry: Identifiable, Hashable {
    let url: URL
    var name: String
    var isPinned: Bool
    var arguments: String
    var id: String { url.path }
}

@MainActor
final class Bottle: ObservableObject, Identifiable {
    let url: URL
    @Published var meta: BottleMetadata { didSet { if meta != oldValue { scheduleSave() } } }
    @Published private(set) var discovered: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var running: [Int32: String] = [:]
    @Published var busyStatus: String?
    @Published var lastError: String?

    private var saveTask: Task<Void, Never>?
    private var appliedRegistry: String?

    nonisolated var id: URL { url }
    var prefix: URL { Wine.prefix(of: url) }
    var driveC: URL { Wine.driveC(of: url) }
    var isReady: Bool { busyStatus == nil && FileManager.default.fileExists(atPath: driveC.path) }

    init(url: URL, meta: BottleMetadata) {
        self.url = url
        self.meta = meta
        self.appliedRegistry = Wine.registryFile(for: meta.settings)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000) // debounce typing / slider drags
            guard let self, !Task.isCancelled else { return }
            await self.saveNow()
        }
    }

    func saveNow() async {
        do { try meta.write(to: url) } catch { lastError = error.localizedDescription }
        let registry = Wine.registryFile(for: meta.settings)
        guard registry != appliedRegistry, isReady else { return }
        appliedRegistry = registry
        do {
            try await Wine.applyRegistry(bottleURL: url, settings: meta.settings)
        } catch {
            appliedRegistry = nil
            lastError = error.localizedDescription
        }
    }

    // MARK: Programs

    var programs: [ProgramEntry] {
        let pinned = meta.pinned.map {
            ProgramEntry(url: URL(fileURLWithPath: $0.path), name: $0.name, isPinned: true, arguments: $0.arguments)
        }
        let pinnedPaths = Set(meta.pinned.map(\.path))
        let others = discovered.filter { !pinnedPaths.contains($0.path) }.map {
            ProgramEntry(url: $0, name: $0.deletingPathExtension().lastPathComponent, isPinned: false, arguments: "")
        }
        return pinned + others
    }

    func togglePin(_ program: ProgramEntry) {
        if let index = meta.pinned.firstIndex(where: { $0.path == program.url.path }) {
            meta.pinned.remove(at: index)
        } else {
            meta.pinned.append(PinnedProgram(path: program.url.path, name: program.name, arguments: program.arguments))
        }
    }

    func updatePinned(_ program: ProgramEntry, name: String, arguments: String) {
        if let index = meta.pinned.firstIndex(where: { $0.path == program.url.path }) {
            meta.pinned[index].name = name
            meta.pinned[index].arguments = arguments
        } else {
            meta.pinned.append(PinnedProgram(path: program.url.path, name: name, arguments: arguments))
        }
    }

    func rescanPrograms() {
        guard !isScanning else { return }
        isScanning = true
        let driveC = self.driveC
        Task {
            let found = await Task.detached(priority: .utility) { ProgramScanner.scan(driveC: driveC) }.value
            self.discovered = found
            self.isScanning = false
        }
    }

    // MARK: Running

    func launch(_ file: URL, arguments: [String] = []) async {
        guard isReady else { return }
        let settings = meta.settings
        let bottleURL = url
        var logHandle: FileHandle?
        if settings.logging {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let logURL = Paths.logs.appendingPathComponent("\(meta.name)-\(file.deletingPathExtension().lastPathComponent)-\(stamp).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
        }

        await Task.detached(priority: .userInitiated) {
            Wine.prepareForLaunch(bottleURL: bottleURL, settings: settings)
        }.value

        let process = Process()
        process.executableURL = Paths.wineBin
        process.arguments = Wine.launchArguments(for: file, arguments: arguments)
        process.environment = Wine.environment(bottleURL: bottleURL, settings: settings, logDirectory: Paths.logs)
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        process.qualityOfService = .userInteractive // games: run Wine at interactive scheduling priority
        let name = file.lastPathComponent
        let log = logHandle
        process.terminationHandler = { [weak self] proc in
            try? log?.close()
            let pid = proc.processIdentifier
            Task { @MainActor in
                self?.running[pid] = nil
                self?.rescanPrograms() // installers usually add new programs
            }
        }
        do {
            try process.run()
            running[process.processIdentifier] = name
        } catch {
            lastError = "Couldn't start \(name): \(error.localizedDescription)"
        }
    }

    func killAll() async {
        await Wine.wineserver(["-k"], bottleURL: url)
        running.removeAll()
    }

    func runTool(_ arguments: [String]) {
        guard isReady else { return }
        let bottleURL = url
        let settings = meta.settings
        Task.detached { _ = try? await Wine.run(arguments, bottleURL: bottleURL, settings: settings) }
    }

    func updatePrefix() async {
        busyStatus = "Updating Windows environment…"
        defer { busyStatus = nil }
        do {
            try await Wine.run(["wineboot", "-u"], bottleURL: url, settings: meta.settings)
            await Wine.wineserver(["-w"], bottleURL: url)
        } catch { lastError = error.localizedDescription }
    }

    /// Opens Terminal with WINEPREFIX/PATH etc. set, for power users and manual winetricks.
    func openTerminal() {
        let env = Wine.environment(bottleURL: url, settings: meta.settings)
        let keys = ["WINEPREFIX", "PATH", "WINEDEBUG", "WINEDLLOVERRIDES", "WINE_LARGE_ADDRESS_AWARE",
                    "DXVK_STATE_CACHE_PATH", "DXVK_CONFIG_FILE", "DXVK_ASYNC", "DXVK_HUD", "DXVK_FILTER_DEVICE_NAME",
                    "DXVK_LOG_LEVEL", "MVK_CONFIG_RESUME_LOST_DEVICE", "MVK_CONFIG_LOG_LEVEL", "MTL_HUD_ENABLED"]
            + meta.settings.environment.keys.sorted()
        var script = "#!/bin/zsh\n"
        for key in Set(keys).sorted() { if let value = env[key] { script += "export \(key)=\(shellQuote(value))\n" } }
        script += "export WINE=\(shellQuote(Paths.wineBin.path))\nexport WINESERVER=\(shellQuote(Paths.wineserverBin.path))\n"
        script += "cd \(shellQuote(driveC.path))\nclear\necho 'Vintner shell for bottle \"\(meta.name.replacingOccurrences(of: "'", with: ""))\". Try: wine winecfg, winetricks <verb>'\nexec /bin/zsh -i\n"
        let file = url.appendingPathComponent("shell.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { lastError = error.localizedDescription }
    }

    /// Creates ~/Applications/Vintner/<name>.app that launches the program directly through
    /// Vintner's headless mode, so games can live in Launchpad/Dock.
    func createLauncher(for program: ProgramEntry) {
        let fm = FileManager.default
        let safeName = program.name.replacingOccurrences(of: "/", with: "-")
        let app = Paths.launchers.appendingPathComponent("\(safeName).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        do {
            try? fm.removeItem(at: app)
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            let vintner = Bundle.main.executablePath ?? "/Applications/Vintner.app/Contents/MacOS/Vintner"
            let args = ["--run", shellQuote(url.path), shellQuote(program.url.path)]
                + splitArguments(program.arguments).map(shellQuote)
            let script = """
            #!/bin/sh
            V=\(shellQuote(vintner))
            [ -x "$V" ] || V="/Applications/Vintner.app/Contents/MacOS/Vintner"
            exec "$V" \(args.joined(separator: " "))

            """
            let exec = macOS.appendingPathComponent("launcher")
            try script.write(to: exec, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
            let plist: [String: Any] = [
                "CFBundleExecutable": "launcher",
                "CFBundleIdentifier": "app.vintner.launcher.\(meta.id.uuidString.prefix(8)).\(safeName.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })",
                "CFBundleName": program.name,
                "CFBundlePackageType": "APPL",
                "LSUIElement": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch { lastError = error.localizedDescription }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Splits a command line honouring double and single quotes ("C:\Program Files\x" stays one argument).
func splitArguments(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var hasToken = false
    for ch in line {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            hasToken = true
        } else if ch.isWhitespace {
            if hasToken { result.append(current); current = ""; hasToken = false }
        } else {
            current.append(ch)
            hasToken = true
        }
    }
    if hasToken { result.append(current) }
    return result
}

enum ProgramScanner {
    private static let skipDirectories: Set<String> = [
        "windows", "common files", "internet explorer", "windows media player", "windows nt",
        "microsoft.net", "windowspowershell", "shadercache", "downloading", "temp", "_commonredist",
        "redist", "redistributables", "directx", "vcredist", "dotnet", "installer", "__installer", "support",
    ]
    private static let skipNamePrefixes = ["unins", "uninstall", "vc_redist", "vcredist", "dxsetup", "dxwebsetup",
                                           "dotnetfx", "ndp4", "crashreport", "crashhandler", "unitycrashhandler",
                                           "iexplore", "wmplayer", "wordpad", "notepad", "winhlp", "ue4prereq",
                                           "easyanticheat_setup", "steamerrorreporter", "quicksfv"]

    /// Finds launchable .exe files under Program Files / users' desktops without walking the
    /// whole prefix (Steam libraries can contain hundreds of thousands of files).
    static func scan(driveC: URL) -> [URL] {
        let fm = FileManager.default
        var roots = ["Program Files", "Program Files (x86)", "ProgramData", "Games", "GOG Games"].map {
            driveC.appendingPathComponent($0, isDirectory: true)
        }
        if let users = try? fm.contentsOfDirectory(at: driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil) {
            roots += users.map { $0.appendingPathComponent("Desktop", isDirectory: true) }
        }

        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in roots where fm.fileExists(atPath: root.path) {
            let rootDepth = root.pathComponents.count
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let item as URL in walker {
                let values = try? item.resourceValues(forKeys: Set(keys))
                let name = item.lastPathComponent.lowercased()
                if values?.isDirectory == true {
                    if values?.isSymbolicLink == true || skipDirectories.contains(name)
                        || item.pathComponents.count - rootDepth >= 6 {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard name.hasSuffix(".exe"), !skipNamePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                results.append(item)
            }
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
