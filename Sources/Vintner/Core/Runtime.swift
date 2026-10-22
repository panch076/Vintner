import Foundation

/// A downloadable runtime component, pinned to an exact file and SHA-256.
struct RuntimeComponent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case wine, dxvk, winetricks }
    var kind: Kind
    var name: String
    var version: String
    var url: URL
    var sha256: String
    /// Directory inside the archive that gets installed (archives only).
    var innerPath: String?
    var id: String { kind.rawValue }
    var fileName: String { url.lastPathComponent }
}

enum RuntimeManifest {
    // Verified 2026-10-22 against the GitHub release asset digests.
    static let components: [RuntimeComponent] = [
        RuntimeComponent(
            kind: .wine, name: "Wine Staging (x86_64, with MoltenVK, Wine Mono & Gecko)", version: "11.18",
            url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!,
            sha256: "b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127",
            innerPath: "Wine Staging.app/Contents/Resources/wine"),
        RuntimeComponent(
            kind: .dxvk, name: "DXVK-macOS (async)", version: "1.10.3-20230507",
            url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507/dxvk-macOS-async-v1.10.3-20230507.tar.gz")!,
            sha256: "f67d99d0a8eeedd7d406b283a3df9f939b5965acb00efcb33d0c6235c195a516",
            innerPath: "dxvk-macOS-async-v1.10.3-20230507"),
        RuntimeComponent(
            kind: .winetricks, name: "Winetricks", version: "20260125",
            url: URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks")!,
            sha256: "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b",
            innerPath: nil),
    ]
}

@MainActor
final class RuntimeManager: ObservableObject {
    enum State: Equatable {
        case missing
        case working(step: String, progress: Double?)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing
    @Published private(set) var installed: [String: RuntimeComponent] = [:]
    @Published private(set) var availableWineUpdate: RuntimeComponent?

    var isReady: Bool { state == .ready }
    var isWorking: Bool { if case .working = state { return true }; return false }
    var hasBundledPayload: Bool {
        guard let payload = Paths.payload else { return false }
        return RuntimeManifest.components.allSatisfy { FileManager.default.fileExists(atPath: payload.appendingPathComponent($0.fileName).path) }
    }

    init() { refresh() }

    func refresh() {
        Paths.ensureDirectories()
        if let data = try? Data(contentsOf: Paths.installedManifest),
           let list = try? JSONDecoder().decode([RuntimeComponent].self, from: data) {
            installed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
        if case .working = state { return }
        state = missingComponents().isEmpty && hasBundledOrInstalledCabextract() ? .ready : .missing
    }

    func missingComponents() -> [RuntimeComponent] {
        let fm = FileManager.default
        return RuntimeManifest.components.filter { component in
            switch component.kind {
            case .wine: return !fm.isExecutableFile(atPath: Paths.wineBin.path)
            case .dxvk: return !fm.fileExists(atPath: Paths.dxvk.appendingPathComponent("x64/d3d11.dll").path)
            case .winetricks: return !fm.isExecutableFile(atPath: Paths.winetricks.path)
            }
        }
    }

    private func hasBundledOrInstalledCabextract() -> Bool {
        FileManager.default.isExecutableFile(atPath: Paths.cabextract.path) || bundledCabextract == nil
    }

    private var bundledCabextract: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/cabextract"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Installs whatever is missing (or the explicitly given components).
    func install(_ components: [RuntimeComponent]? = nil) async {
        guard !isWorking else { return }
        let todo = components ?? missingComponents()
        do {
            for (index, component) in todo.enumerated() {
                let prefix = todo.count > 1 ? "(\(index + 1)/\(todo.count)) " : ""
                let archive = try await obtain(component, label: prefix)
                state = .working(step: "\(prefix)Installing \(component.name)…", progress: nil)
                try await Task.detached(priority: .userInitiated) {
                    try Self.installFiles(component, from: archive)
                }.value
                record(component)
            }
            try installCabextract()
            state = .ready
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Looks for a newer Wine Staging build on GitHub. Uses the asset's published SHA-256 digest
    /// so updates are verified exactly like the pinned version.
    func checkForWineUpdate() async {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
            let tag_name: String
            let assets: [Asset]
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let asset = release.assets.first(where: { $0.name.hasPrefix("wine-staging-") && $0.name.hasSuffix("osx64.tar.xz") }),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else {
                availableWineUpdate = nil
                return
            }
            let current = installed[RuntimeComponent.Kind.wine.rawValue]?.version ?? ""
            guard release.tag_name != current else { availableWineUpdate = nil; return }
            availableWineUpdate = RuntimeComponent(
                kind: .wine, name: "Wine Staging (x86_64, with MoltenVK, Wine Mono & Gecko)", version: release.tag_name,
                url: asset.browser_download_url, sha256: String(digest.dropFirst("sha256:".count)),
                innerPath: "Wine Staging.app/Contents/Resources/wine")
        } catch {
            availableWineUpdate = nil
        }
    }

    func removeRuntime() {
        try? FileManager.default.removeItem(at: Paths.runtime)
        installed = [:]
        refresh()
    }

    // MARK: Internals

    private func obtain(_ component: RuntimeComponent, label: String) async throws -> URL {
        let fm = FileManager.default
        if let payload = Paths.payload?.appendingPathComponent(component.fileName), fm.fileExists(atPath: payload.path) {
            state = .working(step: "\(label)Verifying bundled \(component.name)…", progress: nil)
            try await verify(payload, component)
            return payload
        }

        let destination = Paths.downloads.appendingPathComponent(component.fileName)
        if fm.fileExists(atPath: destination.path) {
            state = .working(step: "\(label)Verifying cached \(component.name)…", progress: nil)
            if (try? await verify(destination, component)) != nil { return destination }
            try? fm.removeItem(at: destination)
        }

        state = .working(step: "\(label)Downloading \(component.name) \(component.version)…", progress: 0)
        let step = "\(label)Downloading \(component.name) \(component.version)…"
        let downloader = Downloader(destination: destination) { [weak self] fraction in
            Task { @MainActor in self?.state = .working(step: step, progress: fraction) }
        }
        _ = try await downloader.download(component.url)
        state = .working(step: "\(label)Verifying \(component.name)…", progress: nil)
        do {
            try await verify(destination, component)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private func verify(_ file: URL, _ component: RuntimeComponent) async throws {
        let hash = try await Task.detached(priority: .userInitiated) { try Checksum.sha256(of: file) }.value
        guard hash.lowercased() == component.sha256.lowercased() else {
            throw DownloadError.checksumMismatch(file: component.fileName)
        }
    }

    nonisolated private static func installFiles(_ component: RuntimeComponent, from file: URL) throws {
        let fm = FileManager.default
        let target: URL
        switch component.kind {
        case .wine: target = Paths.wineRoot
        case .dxvk: target = Paths.dxvk
        case .winetricks:
            try? fm.removeItem(at: Paths.winetricks)
            try fm.copyItem(at: file, to: Paths.winetricks)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.winetricks.path)
            return
        }

        // Extract into a staging directory on the same volume, then swap atomically-ish.
        let staging = Paths.runtime.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", file.path, "-C", staging.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw ShellError.failed("Extracting \(component.fileName)", tar.terminationStatus) }

        let extracted = staging.appendingPathComponent(component.innerPath ?? "", isDirectory: true)
        guard fm.fileExists(atPath: extracted.path) else {
            throw ShellError.failed("Unexpected archive layout in \(component.fileName)", 1)
        }
        // Never let quarantine flags ride along; Gatekeeper would block every Wine dylib.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", extracted.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        let old = Paths.runtime.appendingPathComponent(".old-\(UUID().uuidString)")
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
        do {
            try fm.moveItem(at: extracted, to: target)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }
            throw error
        }
        try? fm.removeItem(at: old)
    }

    private func installCabextract() throws {
        guard let bundled = bundledCabextract else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.cabextract)
        try fm.copyItem(at: bundled, to: Paths.cabextract)
    }

    private func record(_ component: RuntimeComponent) {
        installed[component.id] = component
        if component.kind == .wine { availableWineUpdate = nil }
        let list = installed.values.sorted { $0.id < $1.id }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Paths.installedManifest, options: .atomic) }
    }
}
