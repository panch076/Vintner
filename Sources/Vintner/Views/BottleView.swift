import SwiftUI
import UniformTypeIdentifiers

struct BottleView: View {
    @ObservedObject var bottle: Bottle
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.programs
    @State private var dropTargeted = false

    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs", settings = "Settings", winetricks = "Winetricks", tools = "Tools"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let status = bottle.busyStatus {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .programs: ProgramsView(bottle: bottle)
                case .settings: BottleSettingsView(bottle: bottle)
                case .winetricks: WinetricksView(bottle: bottle)
                case .tools: ToolsView(bottle: bottle)
                }
            }
        }
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["exe", "msi", "bat", "lnk", "com"].contains(url.pathExtension.lowercased()) else { return }
                    Task { @MainActor in await bottle.launch(url) }
                }
            }
            return true
        }
        .alert("Error", isPresented: Binding(get: { bottle.lastError != nil }, set: { if !$0 { bottle.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bottle.lastError ?? "")
        }
        .onAppear { model.lastBottleURL = bottle.url }
        .navigationTitle(bottle.meta.name)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.meta.name).font(.title2.bold())
                Text(statusText).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            Spacer()
            Button { chooseFile() } label: { Label("Run…", systemImage: "play.fill") }
                .disabled(!bottle.isReady)
                .help("Run an .exe, .msi, .bat or .lnk in this bottle (or drop files here)")
            Button { Task { await bottle.killAll() } } label: { Label("Stop All", systemImage: "stop.fill") }
                .disabled(!bottle.isReady)
                .help("Force-quit every Windows program in this bottle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        let s = bottle.meta.settings
        var parts = [s.windowsVersion.title, s.graphics == .dxvk ? "DXVK" : (s.graphics == .wined3dGL ? "WineD3D GL" : "WineD3D Vulkan")]
        if !bottle.running.isEmpty { parts.append("Running: " + bottle.running.values.sorted().joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["exe", "msi", "bat", "lnk", "com"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            Task { await bottle.launch(url) }
        }
    }
}

// MARK: - Programs

struct ProgramsView: View {
    @ObservedObject var bottle: Bottle
    @State private var search = ""
    @State private var editing: ProgramEntry?

    private var filtered: [ProgramEntry] {
        let all = bottle.programs
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search programs", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                if bottle.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                Button { bottle.rescanPrograms() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
            .padding(12)
            if filtered.isEmpty && !bottle.isScanning {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("No programs found yet.").font(.headline)
                    Text("Click Run… to start an installer (for example SteamSetup.exe), or drag an .exe onto this window.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { program in
                    ProgramRow(bottle: bottle, program: program, onEdit: { editing = program })
                }
            }
        }
        .onAppear { if bottle.discovered.isEmpty { bottle.rescanPrograms() } }
        .sheet(item: $editing) { ProgramEditSheet(bottle: bottle, program: $0) }
    }
}

private struct ProgramRow: View {
    @ObservedObject var bottle: Bottle
    let program: ProgramEntry
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: program.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(program.name).font(.body.weight(.medium))
                    if program.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundColor(.accentColor) }
                }
                Text(displayPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { Task { await bottle.launch(program.url, arguments: splitArguments(program.arguments)) } } label: {
                Image(systemName: "play.fill")
            }
            .help("Run")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Run") { Task { await bottle.launch(program.url, arguments: splitArguments(program.arguments)) } }
            Button(program.isPinned ? "Unpin" : "Pin to Top") { bottle.togglePin(program) }
            Button("Edit Name & Arguments…") { onEdit() }
            Button("Create App Shortcut (Launchpad/Dock)") { bottle.createLauncher(for: program) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([program.url]) }
        }
    }

    private var displayPath: String {
        let base = bottle.driveC.path
        return program.url.path.hasPrefix(base) ? "C:" + program.url.path.dropFirst(base.count).replacingOccurrences(of: "/", with: "\\") : program.url.path
    }
}

private struct ProgramEditSheet: View {
    @ObservedObject var bottle: Bottle
    let program: ProgramEntry
    @Environment(\.presentationMode) private var presentationMode
    @State private var name = ""
    @State private var arguments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Program").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Launch arguments", text: $arguments)
            }
            Text("Saving pins the program to the top of the list.").font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    bottle.updatePinned(program, name: name, arguments: arguments)
                    presentationMode.wrappedValue.dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { name = program.name; arguments = program.arguments }
    }
}
