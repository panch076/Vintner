import Foundation

/// Everything needed to talk to Wine. Pure/nonisolated so it is shared by the GUI and the
/// headless `--run` launcher mode used by generated app shortcuts.
enum Wine {
    static let dxvkDLLs = ["d3d11.dll", "d3d10core.dll", "dxgi.dll"]

    static func prefix(of bottleURL: URL) -> URL { bottleURL.appendingPathComponent("prefix", isDirectory: true) }
    static func driveC(of bottleURL: URL) -> URL { prefix(of: bottleURL).appendingPathComponent("drive_c", isDirectory: true) }

    // MARK: Environment

    static func environment(bottleURL: URL, settings: BottleSettings, logDirectory: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }

        env["WINEPREFIX"] = prefix(of: bottleURL).path
        env["PATH"] = [Paths.wineRoot.appendingPathComponent("bin").path, Paths.toolsBin.path,
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        // Debug channels cost real CPU time in Wine; silence them unless logging is on.
        env["WINEDEBUG"] = settings.logging ? "fixme-all" : "-all"

        var overrides = ["winemenubuilder.exe=d"] // no stray Linux .desktop files / menu scanning
        switch settings.graphics {
        case .dxvk: overrides.append("d3d11,d3d10core,dxgi=n,b")
        case .wined3dGL, .wined3dVulkan: overrides.append("d3d11,d3d10core,dxgi=b")
        }
        if let user = settings.environment["WINEDLLOVERRIDES"], !user.isEmpty { overrides.append(user) }
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")

        if settings.largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = "1" } // wine-staging: 4 GB for 32-bit games

        // DXVK
        let cache = bottleURL.appendingPathComponent("cache/dxvk", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["DXVK_STATE_CACHE_PATH"] = cache.path // persistent pipeline cache = less stutter on later runs
        env["DXVK_CONFIG_FILE"] = bottleURL.appendingPathComponent("dxvk.conf").path
        if settings.dxvkAsync { env["DXVK_ASYNC"] = "1" }
        if let hud = settings.dxvkHUD.envValue { env["DXVK_HUD"] = hud }
        if let gpu = settings.preferredGPU, !gpu.isEmpty { env["DXVK_FILTER_DEVICE_NAME"] = gpu }

        // MoltenVK / Metal
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }

        if settings.logging, let logDirectory {
            env["DXVK_LOG_PATH"] = logDirectory.path
            env["DXVK_LOG_LEVEL"] = "info"
        } else {
            env["DXVK_LOG_LEVEL"] = "none"
            env["MVK_CONFIG_LOG_LEVEL"] = "0"
        }

        for (key, value) in settings.environment where key != "WINEDLLOVERRIDES" { env[key] = value }
        return env
    }

    // MARK: Prefix preparation

    /// Makes sure the bottle's prefix matches its settings before a launch. Cheap when nothing changed.
    static func prepareForLaunch(bottleURL: URL, settings: BottleSettings) {
        writeDXVKConfig(bottleURL: bottleURL, settings: settings)
        if settings.graphics == .dxvk { syncDXVK(prefix: prefix(of: bottleURL), include32Bit: settings.dxvk32Bit) }
    }

    /// Puts DXVK into system32 (and syswow64 when 32-bit DXVK is enabled), re-copying when
    /// missing or replaced (e.g. after a Wine update ran `wineboot -u`).
    ///
    /// 32-bit DXVK is off by default: under Wine's WoW64 mode, 32-bit Vulkan memory has to be
    /// mapped below 4 GB, and Wine does that by importing host memory, which MoltenVK rejects
    /// ("Only external memory handle type ..._MTLBUFFER_BIT_EXT ... supported"). With Wine's own
    /// DLLs in syswow64, the "n,b" override falls back to WineD3D for 32-bit processes only, so
    /// a 32-bit launcher and a 64-bit game in the same bottle both work.
    static func syncDXVK(prefix: URL, include32Bit: Bool) {
        let fm = FileManager.default
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        for (arch, folder, wineArch, useDXVK) in [("x64", "system32", "x86_64-windows", true),
                                                  ("x32", "syswow64", "i386-windows", include32Bit)] {
            let target = windows.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: target.path) else { continue }
            for dll in dxvkDLLs {
                let src = useDXVK ? Paths.dxvk.appendingPathComponent(arch).appendingPathComponent(dll)
                                  : Paths.wineRoot.appendingPathComponent("lib/wine/\(wineArch)/\(dll)")
                let dst = target.appendingPathComponent(dll)
                guard let srcSize = fileSize(src) else { continue }
                if fileSize(dst) == srcSize { continue }
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    static func writeDXVKConfig(bottleURL: URL, settings: BottleSettings) {
        var lines = ["# Generated by Vintner. Edit settings in the app instead."]
        lines.append("dxvk.enableAsync = \(settings.dxvkAsync ? "True" : "False")")
        if settings.frameRateLimit > 0 {
            lines.append("dxgi.maxFrameRate = \(settings.frameRateLimit)")
            lines.append("d3d9.maxFrameRate = \(settings.frameRateLimit)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        let url = bottleURL.appendingPathComponent("dxvk.conf")
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The registry state implied by the settings, as a .reg file. Applied with one regedit call
    /// instead of one `wine reg add` per value (each wine invocation costs ~0.5–1 s).
    static func registryFile(for settings: BottleSettings) -> String {
        func yn(_ b: Bool) -> String { b ? "\"y\"" : "\"n\"" }
        let renderer = settings.graphics == .wined3dVulkan ? "vulkan" : "gl"
        return """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Wine]
        "Version"="\(settings.windowsVersion.rawValue)"

        [HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
        "renderer"="\(renderer)"
        "csmt"=dword:00000001

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"=\(yn(settings.retinaMode))
        "CaptureDisplaysForFullscreen"=\(yn(settings.captureDisplays))
        "LeftCommandIsCtrl"=\(yn(settings.commandAsCtrl))
        "RightCommandIsCtrl"=\(yn(settings.commandAsCtrl))
        "LeftOptionIsAlt"=\(yn(settings.optionAsAlt))
        "RightOptionIsAlt"=\(yn(settings.optionAsAlt))

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(String(format: "%08x", settings.dpi))

        """
    }

    // MARK: Running

    /// Arguments for launching a file with `wine`. Executables run directly (so we can track
    /// their lifetime); everything else goes through `start /wait /unix` which handles
    /// .msi/.bat/.lnk via ShellExecute.
    static func launchArguments(for file: URL, arguments: [String]) -> [String] {
        if file.pathExtension.lowercased() == "exe" {
            return [file.path] + arguments
        }
        return ["start", "/wait", "/unix", file.path] + arguments
    }

    @discardableResult
    static func run(_ arguments: [String], bottleURL: URL, settings: BottleSettings,
                    extraEnvironment: [String: String] = [:], log: FileHandle? = nil) async throws -> Int32 {
        var env = environment(bottleURL: bottleURL, settings: settings)
        env.merge(extraEnvironment) { _, new in new }
        return try await Shell.run(Paths.wineBin, arguments, environment: env, output: log)
    }

    static func wineserver(_ arguments: [String], bottleURL: URL) async {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        env["WINEPREFIX"] = prefix(of: bottleURL).path
        _ = try? await Shell.run(Paths.wineserverBin, arguments, environment: env)
    }

    static func applyRegistry(bottleURL: URL, settings: BottleSettings) async throws {
        let temp = driveC(of: bottleURL).appendingPathComponent("windows/temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try registryFile(for: settings).write(to: temp.appendingPathComponent("vintner.reg"), atomically: true, encoding: .utf8)
        let status = try await run(["regedit", "/S", "C:\\windows\\temp\\vintner.reg"], bottleURL: bottleURL, settings: settings)
        guard status == 0 else { throw ShellError.failed("Applying registry settings", status) }
    }

    /// Creates a fresh prefix. Wine Mono and Gecko are installed silently from the runtime.
    static func createPrefix(bottleURL: URL, settings: BottleSettings, log: FileHandle?) async throws {
        try FileManager.default.createDirectory(at: prefix(of: bottleURL), withIntermediateDirectories: true)
        let status = try await run(["wineboot", "--init"], bottleURL: bottleURL, settings: settings, log: log)
        guard status == 0 else { throw ShellError.failed("Creating the Windows environment", status) }
        try await applyRegistry(bottleURL: bottleURL, settings: settings)
        prepareForLaunch(bottleURL: bottleURL, settings: settings)
        await wineserver(["-w"], bottleURL: bottleURL) // let wineserver flush the registry to disk
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}
