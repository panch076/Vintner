import SwiftUI

struct BottleSettingsView: View {
    @ObservedObject var bottle: Bottle
    @State private var envText = ""
    private let system = SystemInfo.current

    private var settings: Binding<BottleSettings> { $bottle.meta.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("General") {
                    TextField("Name", text: $bottle.meta.name)
                    Picker("Windows version", selection: settings.windowsVersion) {
                        ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                    }
                }

                section("Graphics") {
                    Picker("Direct3D backend", selection: settings.graphics) {
                        ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                    }
                    note(graphicsNote)
                    if !system.canUseDXVK && bottle.meta.settings.graphics != .wined3dGL {
                        Label("No Metal 2 GPU detected; Vulkan backends will fail on this Mac.", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                    Toggle("DXVK async shader compilation (less stutter)", isOn: settings.dxvkAsync)
                        .disabled(bottle.meta.settings.graphics != .dxvk)
                    note("Compiles shaders in the background instead of pausing the game. May cause brief visual pop-in. Some online games' anti-cheat may object to modified DLLs.")
                    Toggle("Use DXVK for 32-bit programs too (experimental)", isOn: settings.dxvk32Bit)
                        .disabled(bottle.meta.settings.graphics != .dxvk)
                    note("Off: 32-bit programs automatically use WineD3D while 64-bit ones use DXVK. Wine's 32-bit Vulkan memory mapping isn't supported by MoltenVK yet; run `Vintner --selftest` to see whether it works on this Mac.")
                    Picker("DXVK HUD", selection: settings.dxvkHUD) {
                        ForEach(DXVKHUD.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(bottle.meta.settings.graphics != .dxvk)
                    Toggle("Metal performance HUD", isOn: settings.metalHUD)
                        .disabled(!system.supportsMetalHUD)
                    if system.gpus.count > 1 {
                        Picker("Preferred GPU (DXVK)", selection: Binding(
                            get: { bottle.meta.settings.preferredGPU ?? "" },
                            set: { bottle.meta.settings.preferredGPU = $0.isEmpty ? nil : $0 })) {
                            Text("Automatic").tag("")
                            ForEach(system.gpus) { Text("\($0.name) (\($0.kind))").tag($0.name) }
                        }
                        note("On Macs and Hackintoshes with both integrated and discrete graphics, pick the discrete GPU for games.")
                    }
                    Stepper(value: settings.frameRateLimit, in: 0 ... 360, step: 10) {
                        Text("Frame rate limit: \(bottle.meta.settings.frameRateLimit == 0 ? "Off" : "\(bottle.meta.settings.frameRateLimit) FPS")")
                    }
                    .disabled(bottle.meta.settings.graphics != .dxvk)
                }

                section("Display") {
                    Toggle("Retina / high-resolution mode", isOn: settings.retinaMode)
                    note("Renders at full Retina resolution. Sharper, but much heavier on the GPU. Leave off for games on Intel GPUs.")
                    Picker("Windows DPI scaling", selection: settings.dpi) {
                        Text("100% (96 DPI)").tag(96)
                        Text("125% (120 DPI)").tag(120)
                        Text("150% (144 DPI)").tag(144)
                        Text("200% (192 DPI)").tag(192)
                    }
                    Toggle("Exclusive fullscreen (capture display)", isOn: settings.captureDisplays)
                    note("Lets fullscreen games take over the display, which can improve frame pacing.")
                }

                section("Keyboard") {
                    Toggle("Use ⌘ Command as Ctrl", isOn: settings.commandAsCtrl)
                    Toggle("Use ⌥ Option as Alt", isOn: settings.optionAsAlt)
                }

                section("Advanced") {
                    Toggle("Large address aware (32-bit games can use 4 GB)", isOn: settings.largeAddressAware)
                    Toggle("Write logs (slower; for troubleshooting)", isOn: settings.logging)
                    note("Logs are written to ~/Library/Logs/Vintner and removed after 7 days.")
                    Text("Environment variables (KEY=VALUE, one per line)").font(.callout)
                    TextEditor(text: $envText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        .onChange(of: envText) { bottle.meta.settings.environment = BottleSettings.parseEnvironment($0) }
                }

                note("Changes are saved automatically and apply the next time a program starts.")
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { envText = BottleSettings.formatEnvironment(bottle.meta.settings.environment) }
    }

    private var graphicsNote: String {
        switch bottle.meta.settings.graphics {
        case .dxvk: return "64-bit Direct3D 10/11 via DXVK on MoltenVK/Metal. Direct3D 8/9 and 32-bit programs use WineD3D; Direct3D 12 uses vkd3d. Best for most modern games."
        case .wined3dGL: return "Translates Direct3D to OpenGL. Use for older GPUs or if a game shows a black screen with DXVK."
        case .wined3dVulkan: return "WineD3D using its Vulkan renderer through MoltenVK. Experimental, and 64-bit programs only: 32-bit programs crash with it."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
