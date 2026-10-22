import AppKit
import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var runtime: RuntimeManager
    private let system = SystemInfo.current

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Vintner").font(.largeTitle.bold())
            Text("Run Windows apps and games on your Intel Mac or Hackintosh.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                check(true, "macOS \(system.osVersion)")
                check(!system.isTranslated, system.isTranslated ? "Running under Rosetta 2 (works, but this app is built for Intel Macs)" : "Intel x86_64 processor: \(system.cpu)")
                check(system.canUseDXVK, system.gpus.isEmpty ? "No Metal GPU found" :
                    "GPU: " + system.gpus.map(\.name).joined(separator: ", ") + (system.canUseDXVK ? "" : " (no Metal 2: DXVK unavailable)"))
                check(system.memoryGB >= 8, "\(system.memoryGB) GB memory")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Vintner will install:").font(.headline)
                ForEach(RuntimeManifest.components) { Text("• \($0.name) \($0.version)") }
                Text("• cabextract (for winetricks)")
            }
            .font(.callout)

            switch runtime.state {
            case let .working(step, progress):
                VStack(spacing: 8) {
                    if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                    Text(step).font(.callout).foregroundColor(.secondary)
                }
                .frame(width: 420)
            case let .failed(message):
                VStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundColor(.red)
                    Button("Try Again") { Task { await runtime.install() } }
                }
            default:
                Button(runtime.hasBundledPayload ? "Install (included, no download)" : "Download & Install (about 200 MB)") {
                    Task { await runtime.install() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func check(_ ok: Bool, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(ok ? .green : .orange)
        }
    }
}

struct RuntimeView: View {
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var store: BottleStore
    @State private var checking = false
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Runtime").font(.title2.bold())
                VStack(spacing: 0) {
                    ForEach(RuntimeManifest.components) { component in
                        let installed = runtime.installed[component.id]
                        HStack {
                            VStack(alignment: .leading) {
                                Text(component.name)
                                Text(installed.map { "Installed: \($0.version)" } ?? "Not installed")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Reinstall") { Task { await runtime.install([installed ?? component]) } }
                                .disabled(runtime.isWorking)
                        }
                        .padding(12)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))

                if case let .working(step, progress) = runtime.state {
                    VStack(alignment: .leading) {
                        if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                        Text(step).font(.caption).foregroundColor(.secondary)
                    }
                }
                if case let .failed(message) = runtime.state {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundColor(.red)
                }

                HStack {
                    Button("Check for Wine Update") {
                        checking = true
                        Task { await runtime.checkForWineUpdate(); checking = false }
                    }
                    .disabled(checking || runtime.isWorking)
                    if checking { ProgressView().controlSize(.small) }
                }
                if let update = runtime.availableWineUpdate {
                    HStack {
                        Text("Wine Staging \(update.version) is available.")
                        Button("Install Update") {
                            Task {
                                for bottle in store.bottles { await bottle.killAll() }
                                await runtime.install([update])
                            }
                        }
                        .disabled(runtime.isWorking)
                    }
                    Text("Running programs are closed first. Open each bottle's Tools → Update Windows Environment afterwards (Wine also does this automatically on next launch).")
                        .font(.caption).foregroundColor(.secondary)
                } else if !checking, runtime.installed["wine"] != nil {
                    Text("Updates are verified against the SHA-256 digest GitHub publishes for each release file.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Divider()
                HStack {
                    Button("Show Runtime in Finder") { NSWorkspace.shared.open(Paths.runtime) }
                    Button("Remove Runtime…") { confirmRemove = true }.disabled(runtime.isWorking)
                }
                Text("Location: \(Paths.runtime.path)").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .confirmationDialog("Remove the Wine runtime?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    for bottle in store.bottles { await bottle.killAll() }
                    runtime.removeRuntime()
                }
            }
        } message: {
            Text("Bottles are kept. You'll be asked to reinstall the runtime.")
        }
    }
}

struct SystemView: View {
    private let system = SystemInfo.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("This Mac").font(.title2.bold())
                card {
                    row("macOS", system.osVersion)
                    row("Model", system.model)
                    row("CPU", "\(system.cpu) (\(system.cores) threads)")
                    row("AVX / AVX2", "\(system.hasAVX ? "Yes" : "No") / \(system.hasAVX2 ? "Yes" : "No")")
                    row("Memory", "\(system.memoryGB) GB")
                    if system.isTranslated { row("Note", "Running under Rosetta 2") }
                }
                Text("Graphics").font(.headline)
                if system.gpus.isEmpty {
                    Label("No Metal-capable GPU detected. Only software/OpenGL rendering will work.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
                ForEach(system.gpus) { gpu in
                    card {
                        row("GPU", gpu.name)
                        row("Type", gpu.kind + (gpu.headless ? " (no display attached)" : ""))
                        row("Usable VRAM", "\(gpu.memoryMB) MB")
                        row("DXVK / MoltenVK", gpu.supportsMoltenVK ? "Supported" : "Not supported (needs Metal 2)")
                    }
                }
                Text("Tips: AMD Radeon GPUs give the best results. On Intel integrated graphics, keep Retina mode off and lower game resolution. Games that need AVX2 won't run on CPUs without it. Anti-cheat protected online games generally don't work under Wine.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}
