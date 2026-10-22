import Foundation

/// `Vintner --selftest`: exercises the same code paths as the GUI (runtime install, bottle
/// creation, registry, DXVK placement, running Windows code) and prints a pass/fail report.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func start() -> Never {
        Task { @MainActor in
            await run()
            print(failures == 0 ? "\nSELFTEST PASSED" : "\nSELFTEST FAILED (\(failures) problem(s))")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    /// Reads HKCU\\Software\\Wine "Version" straight from user.reg once wineserver has flushed it.
    private static func registryVersion(_ bottle: Bottle) async -> String? {
        await Wine.wineserver(["-w"], bottleURL: bottle.url)
        guard let reg = try? String(contentsOf: bottle.prefix.appendingPathComponent("user.reg"), encoding: .utf8),
              let section = reg.range(of: "[Software\\\\Wine] ") else { return nil }
        for line in reg[section.upperBound...].split(separator: "\n").dropFirst() {
            if line.hasPrefix("[") { break }
            if line.hasPrefix("\"Version\"=") {
                return line.dropFirst("\"Version\"=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    /// Renders 60 frames with Direct3D 11 through each backend using the bundled probe programs
    /// (source in Vendor/d3dprobe). A small window appears briefly.
    private static func graphicsProbe(_ bottle: Bottle) async {
        guard let probes = Bundle.main.resourceURL?.appendingPathComponent("probe"),
              FileManager.default.fileExists(atPath: probes.appendingPathComponent("probe64.exe").path) else {
            print("SKIP  Direct3D probes not bundled")
            return
        }
        for exe in ["probe64.exe", "probe32.exe"] {
            let dst = bottle.driveC.appendingPathComponent(exe)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: probes.appendingPathComponent(exe), to: dst)
        }
        func probe(_ exe: String, _ settings: BottleSettings) async -> (Int32, String) {
            Wine.prepareForLaunch(bottleURL: bottle.url, settings: settings)
            let result = bottle.driveC.appendingPathComponent("probe.txt")
            try? FileManager.default.removeItem(at: result)
            let code = (try? await Wine.run(["C:\\\(exe)", "C:\\probe.txt"], bottleURL: bottle.url, settings: settings)) ?? -1
            let text = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
            return (code, text.split(whereSeparator: \.isNewline).joined(separator: "; "))
        }
        func rendered(_ r: (Int32, String), _ backend: String) -> Bool {
            r.0 == 0 && r.1.contains("create hr=0x00000000") && r.1.contains("present hr=0x00000000") && r.1.contains("backend=\(backend)")
        }

        var settings = bottle.meta.settings
        if SystemInfo.current.canUseDXVK {
            settings.graphics = .dxvk
            settings.dxvk32Bit = false
            let r64 = await probe("probe64.exe", settings)
            check(rendered(r64, "DXVK"), "Direct3D 11, 64-bit, DXVK → MoltenVK → Metal: \(r64.1)")
            let r32 = await probe("probe32.exe", settings)
            check(rendered(r32, "WineD3D"), "Direct3D 11, 32-bit, DXVK bottle (auto WineD3D fallback): \(r32.1)")

            settings.dxvk32Bit = true
            let x32 = await probe("probe32.exe", settings)
            print("INFO  Experimental 32-bit DXVK: \(rendered(x32, "DXVK") ? "WORKS on this Mac, you can enable it per bottle" : "not working here (expected with current Wine/MoltenVK)")")
            settings.dxvk32Bit = false
            Wine.prepareForLaunch(bottleURL: bottle.url, settings: settings) // restore Wine's 32-bit DLLs
        }
        settings.graphics = .wined3dGL
        for exe in ["probe64.exe", "probe32.exe"] {
            let r = await probe(exe, settings)
            check(rendered(r, "WineD3D"), "Direct3D 11, \(exe.contains("64") ? "64" : "32")-bit, WineD3D (OpenGL): \(r.1)")
        }
    }

    private static func run() async {
        let sys = SystemInfo.current
        print("Vintner self-test")
        print("macOS \(sys.osVersion) · \(sys.cpu) · \(sys.memoryGB) GB\(sys.isTranslated ? " · Rosetta 2" : "")")
        for gpu in sys.gpus { print("GPU: \(gpu.name) [\(gpu.kind)] Metal2=\(gpu.supportsMoltenVK)") }
        check(!sys.gpus.isEmpty, "Metal GPU present")
        check(sys.canUseDXVK, "GPU supports MoltenVK (DXVK usable)")

        let runtime = RuntimeManager()
        if !runtime.isReady {
            print("…installing runtime")
            await runtime.install()
        }
        if case let .failed(message) = runtime.state { print("      \(message)") }
        check(runtime.isReady, "Runtime installed (\(runtime.installed.values.map { "\($0.kind.rawValue) \($0.version)" }.sorted().joined(separator: ", ")))")
        guard runtime.isReady else { return }

        let (status, version) = (try? await Shell.capture(Paths.wineBin, ["--version"])) ?? (-1, "")
        check(status == 0, "wine --version → \(version.trimmingCharacters(in: .whitespacesAndNewlines))")

        let store = BottleStore()
        let started = Date()
        guard let bottle = await store.create(name: "Vintner SelfTest", settings: BottleSettings()) else {
            check(false, "Create bottle folder")
            return
        }
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        check(bottle.lastError == nil && bottle.isReady,
              "Create bottle (\(Int(Date().timeIntervalSince(started))) s)\(bottle.lastError.map { ": " + $0 } ?? "")")
        guard bottle.isReady else { return }

        let windows = bottle.driveC.appendingPathComponent("windows")
        check(FileManager.default.fileExists(atPath: windows.appendingPathComponent("system32/kernel32.dll").path), "64-bit system32 populated")
        check(FileManager.default.fileExists(atPath: windows.appendingPathComponent("syswow64/kernel32.dll").path), "32-bit syswow64 populated (WoW64)")
        check(FileManager.default.fileExists(atPath: windows.appendingPathComponent("Microsoft.NET").path), "Wine Mono installed (.NET apps)")

        for dll in Wine.dxvkDLLs {
            let a = try? Data(contentsOf: windows.appendingPathComponent("system32/\(dll)"))
            let b = try? Data(contentsOf: Paths.dxvk.appendingPathComponent("x64/\(dll)"))
            check(a != nil && a == b, "DXVK \(dll) installed in system32")
        }

        // Run 64-bit and 32-bit Windows code and capture their output through files in C:.
        for (label, exe) in [("64-bit", "C:\\windows\\system32\\cmd.exe"), ("32-bit", "C:\\windows\\syswow64\\cmd.exe")] {
            try? FileManager.default.removeItem(at: bottle.driveC.appendingPathComponent("out.txt"))
            let code = (try? await Wine.run([exe, "/c", "echo vintner-ok>C:\\out.txt"], bottleURL: bottle.url, settings: bottle.meta.settings)) ?? -1
            let text = (try? String(contentsOf: bottle.driveC.appendingPathComponent("out.txt"), encoding: .utf8)) ?? ""
            check(code == 0 && text.contains("vintner-ok"), "\(label) Windows program runs (cmd.exe)")
        }

        check(await registryVersion(bottle) == "win10", "Registry settings applied (Windows version = win10)")

        // Settings change → registry re-applied through the same path the GUI uses.
        bottle.meta.settings.windowsVersion = .win7
        await bottle.saveNow()
        check(await registryVersion(bottle) == "win7", "Changing settings updates the registry (win7)")

        await graphicsProbe(bottle)

        let found = ProgramScanner.scan(driveC: bottle.driveC)
        check(true, "Program scan ran (\(found.count) programs found in a fresh bottle)")

        if FileManager.default.isExecutableFile(atPath: Paths.cabextract.path) {
            let (cabStatus, _) = (try? await Shell.capture(Paths.cabextract, ["--version"])) ?? (-1, "")
            check(cabStatus == 0, "cabextract runs")
        }
        let (wtStatus, wtVersion) = (try? await Shell.capture(Paths.winetricks, ["--version"])) ?? (-1, "")
        check(wtStatus == 0, "winetricks runs (\(wtVersion.trimmingCharacters(in: .whitespacesAndNewlines)))")

        await Wine.wineserver(["-k"], bottleURL: bottle.url)
    }
}
