import Foundation

enum WindowsVersion: String, CaseIterable, Codable, Identifiable {
    case win11, win10, win81, win8, win7, winxp64
    var id: String { rawValue }
    var title: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win8: return "Windows 8"
        case .win7: return "Windows 7"
        case .winxp64: return "Windows XP (64-bit)"
        }
    }
}

enum GraphicsBackend: String, CaseIterable, Codable, Identifiable {
    /// D3D10/11 -> DXVK -> MoltenVK -> Metal. D3D8/9 still go through WineD3D (OpenGL).
    case dxvk
    /// Everything through WineD3D on OpenGL. Most compatible, slowest for D3D11.
    case wined3dGL
    /// WineD3D with its Vulkan renderer (runs on MoltenVK). Experimental.
    case wined3dVulkan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dxvk: return "DXVK → MoltenVK → Metal (recommended)"
        case .wined3dGL: return "WineD3D (OpenGL)"
        case .wined3dVulkan: return "WineD3D (Vulkan, experimental)"
        }
    }
}

enum DXVKHUD: String, CaseIterable, Codable, Identifiable {
    case off, fps, standard, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .fps: return "FPS"
        case .standard: return "GPU, FPS & frame times"
        case .full: return "Everything"
        }
    }
    var envValue: String? {
        switch self {
        case .off: return nil
        case .fps: return "fps"
        case .standard: return "devinfo,fps,frametimes"
        case .full: return "full"
        }
    }
}

struct BottleSettings: Codable, Equatable {
    var windowsVersion: WindowsVersion = .win10
    var graphics: GraphicsBackend = .dxvk
    var dxvkAsync = true
    var dxvk32Bit = false
    var dxvkHUD: DXVKHUD = .off
    var metalHUD = false
    var preferredGPU: String? = nil
    var frameRateLimit = 0
    var retinaMode = false
    var dpi = 96
    var captureDisplays = false
    var commandAsCtrl = false
    var optionAsAlt = false
    var largeAddressAware = true
    var logging = false
    var environment: [String: String] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case windowsVersion, graphics, dxvkAsync, dxvk32Bit, dxvkHUD, metalHUD, preferredGPU, frameRateLimit
        case retinaMode, dpi, captureDisplays, commandAsCtrl, optionAsAlt, largeAddressAware, logging, environment
    }

    /// Tolerant decoding: missing or unknown values fall back to defaults so settings files
    /// written by older/newer versions never make a bottle disappear.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = BottleSettings()
        windowsVersion = value(.windowsVersion, d.windowsVersion)
        graphics = value(.graphics, d.graphics)
        dxvkAsync = value(.dxvkAsync, d.dxvkAsync)
        dxvk32Bit = value(.dxvk32Bit, d.dxvk32Bit)
        dxvkHUD = value(.dxvkHUD, d.dxvkHUD)
        metalHUD = value(.metalHUD, d.metalHUD)
        preferredGPU = value(.preferredGPU, d.preferredGPU)
        frameRateLimit = value(.frameRateLimit, d.frameRateLimit)
        retinaMode = value(.retinaMode, d.retinaMode)
        dpi = value(.dpi, d.dpi)
        captureDisplays = value(.captureDisplays, d.captureDisplays)
        commandAsCtrl = value(.commandAsCtrl, d.commandAsCtrl)
        optionAsAlt = value(.optionAsAlt, d.optionAsAlt)
        largeAddressAware = value(.largeAddressAware, d.largeAddressAware)
        logging = value(.logging, d.logging)
        environment = value(.environment, d.environment)
    }
}

struct PinnedProgram: Codable, Equatable, Identifiable {
    var path: String
    var name: String
    var arguments: String = ""
    var id: String { path }
}

struct BottleMetadata: Codable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var settings = BottleSettings()
    var pinned: [PinnedProgram] = []

    static let fileName = "bottle.json"

    init(name: String, settings: BottleSettings = BottleSettings()) {
        self.name = name
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey { case id, name, created, settings, pinned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        settings = (try? c.decodeIfPresent(BottleSettings.self, forKey: .settings)) ?? BottleSettings()
        pinned = (try? c.decodeIfPresent([PinnedProgram].self, forKey: .pinned)) ?? []
    }

    static func load(from bottleURL: URL) -> BottleMetadata? {
        guard let data = try? Data(contentsOf: bottleURL.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BottleMetadata.self, from: data)
    }

    func write(to bottleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: bottleURL.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension BottleSettings {
    /// Parses "KEY=VALUE" lines (blank lines and # comments ignored).
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }

    static func formatEnvironment(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    }
}
