import AppKit
import SwiftUI

// MARK: - Winetricks

struct WinetricksView: View {
    @ObservedObject var bottle: Bottle
    @StateObject private var run = WinetricksRun()
    @State private var selected: Set<String> = []
    @State private var custom = ""

    private static let common: [(verb: String, title: String)] = [
        ("vcrun2022", "Visual C++ 2015–2022 runtime"),
        ("vcrun2010", "Visual C++ 2010 runtime"),
        ("vcrun2008", "Visual C++ 2008 runtime"),
        ("d3dx9", "DirectX 9 D3DX libraries"),
        ("d3dx11_43", "DirectX 11 D3DX libraries"),
        ("d3dcompiler_47", "D3D shader compiler 47"),
        ("xact", "XACT audio (older games)"),
        ("xinput", "XInput controllers"),
        ("faudio", "FAudio (XAudio2 replacement)"),
        ("physx", "NVIDIA PhysX (CPU)"),
        ("xna40", "XNA Framework 4.0"),
        ("dotnet48", ".NET Framework 4.8 (slow to install)"),
        ("dotnetdesktop8", ".NET 8 Desktop Runtime"),
        ("mfc140", "MFC 14.0"),
        ("vb6run", "Visual Basic 6 runtime"),
        ("corefonts", "Microsoft core fonts"),
        ("gdiplus", "GDI+"),
        ("msxml6", "MSXML 6"),
        ("quartz", "DirectShow (quartz)"),
    ]

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Common components").font(.headline)
                List(Self.common, id: \.verb) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.verb) },
                                         set: { if $0 { selected.insert(item.verb) } else { selected.remove(item.verb) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                            Text(item.verb).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                TextField("Other verbs (space separated)", text: $custom).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Install Selected") {
                        let verbs = Self.common.map(\.verb).filter(selected.contains) + custom.split(separator: " ").map(String.init)
                        run.start(verbs: verbs, bottle: bottle)
                    }
                    .disabled(run.isRunning || (selected.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty))
                    if run.isRunning { ProgressView().controlSize(.small) }
                }
                Text("Downloads are cached in ~/Library/Caches/Vintner.").font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            LogTextView(text: run.output)
                .frame(minWidth: 300)
        }
    }
}

/// NSTextView-backed log viewer: SwiftUI Text re-lays out the whole string on every update,
/// which gets slow with long installer logs.
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.backgroundColor = .textBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let current = storage.string
        let attrs: [NSAttributedString.Key: Any] = [.font: view.font as Any, .foregroundColor: NSColor.textColor]
        if text.hasPrefix(current) && !current.isEmpty {
            let added = String(text.dropFirst(current.count))
            guard !added.isEmpty else { return }
            storage.append(NSAttributedString(string: added, attributes: attrs))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        view.scrollToEndOfDocument(nil)
    }
}

// MARK: - Tools

struct ToolsView: View {
    @ObservedObject var bottle: Bottle
    @EnvironmentObject private var store: BottleStore
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Windows tools") {
                    tool("Wine Configuration", "gearshape", "Libraries, drives, audio, Windows version") { bottle.runTool(["winecfg"]) }
                    tool("Registry Editor", "list.bullet.rectangle", "regedit") { bottle.runTool(["regedit"]) }
                    tool("Task Manager", "chart.bar", "See and end Windows processes") { bottle.runTool(["taskmgr"]) }
                    tool("Control Panel", "slider.horizontal.3", "Game controllers, add/remove programs") { bottle.runTool(["control"]) }
                    tool("Command Prompt", "terminal", "cmd.exe") { bottle.runTool(["wineconsole", "cmd"]) }
                    tool("File Explorer", "folder", "Windows Explorer") { bottle.runTool(["explorer"]) }
                }
                group("Mac tools") {
                    tool("Open C: Drive in Finder", "externaldrive", bottle.driveC.path) { NSWorkspace.shared.open(bottle.driveC) }
                    tool("Open Terminal Here", "terminal.fill", "Shell with WINEPREFIX, wine and winetricks ready") { bottle.openTerminal() }
                    tool("Open Logs Folder", "doc.text.magnifyingglass", Paths.logs.path) {
                        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.logs)
                    }
                }
                group("Maintenance") {
                    tool("Install Steam", "gamecontroller", "Downloads the official SteamSetup.exe and runs it") { installSteam() }
                    tool("Update Windows Environment", "arrow.triangle.2.circlepath", "Runs wineboot -u (after a Wine update)") {
                        Task { await bottle.updatePrefix() }
                    }
                    tool("Force Quit Everything", "xmark.octagon", "wineserver -k") { Task { await bottle.killAll() } }
                    tool("Move Bottle to Trash", "trash", "Deletes this bottle and everything installed in it") { confirmDelete = true }
                }
            }
            .padding(20)
        }
        .confirmationDialog("Move “\(bottle.meta.name)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                let target = bottle
                model.selection = .system
                Task { await store.delete(target) }
            }
        } message: {
            Text("All programs and saves inside this bottle go with it. You can restore it from the Trash.")
        }
    }

    private func installSteam() {
        let url = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        let destination = Paths.downloads.appendingPathComponent("SteamSetup.exe")
        bottle.busyStatus = "Downloading SteamSetup.exe…"
        Task {
            do {
                _ = try await Downloader(destination: destination) { _ in }.download(url)
                bottle.busyStatus = nil
                await bottle.launch(destination)
            } catch {
                bottle.busyStatus = nil
                bottle.lastError = "Steam download failed: \(error.localizedDescription)"
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private func tool(_ title: String, _ icon: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!bottle.isReady)
    }
}
