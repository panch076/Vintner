import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var store: BottleStore

    var body: some View {
        Group {
            if runtime.isReady {
                mainView
            } else {
                SetupView()
            }
        }
        .sheet(isPresented: $model.showNewBottle) { NewBottleSheet() }
        .sheet(isPresented: Binding(get: { !model.filesToOpen.isEmpty && runtime.isReady },
                                    set: { if !$0 { model.filesToOpen = [] } })) {
            RunFileSheet(files: model.filesToOpen)
        }
        .alert("Vintner", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var mainView: some View {
        NavigationView {
            SidebarView()
            DetailView()
        }
        .onAppear {
            if model.selection == nil {
                model.selection = store.bottles.first.map { .bottle($0.url) } ?? .system
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: BottleStore

    var body: some View {
        List(selection: $model.selection) {
            Section(header: Text("Bottles")) {
                ForEach(store.bottles) { bottle in
                    BottleRow(bottle: bottle).tag(SidebarItem.bottle(bottle.url))
                }
                if store.bottles.isEmpty {
                    Text("No bottles yet").foregroundColor(.secondary)
                }
            }
            Section(header: Text("Vintner")) {
                Label("Runtime", systemImage: "shippingbox").tag(SidebarItem.runtime)
                Label("This Mac", systemImage: "desktopcomputer").tag(SidebarItem.system)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button { model.showNewBottle = true } label: { Label("New Bottle", systemImage: "plus") }
                    .help("Create a new bottle (Windows environment)")
            }
        }
    }
}

private struct BottleRow: View {
    @ObservedObject var bottle: Bottle
    var body: some View {
        HStack {
            Label(bottle.meta.name, systemImage: "square.stack.3d.up")
            Spacer()
            if bottle.busyStatus != nil {
                ProgressView().controlSize(.small)
            } else if !bottle.running.isEmpty {
                Image(systemName: "play.circle.fill").foregroundColor(.green).help("Running")
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: BottleStore

    var body: some View {
        switch model.selection {
        case let .bottle(url):
            if let bottle = store.bottle(for: url) {
                BottleView(bottle: bottle).id(url)
            } else {
                placeholder
            }
        case .runtime: RuntimeView()
        case .system: SystemView()
        case .none: placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Create a bottle to start running Windows programs.").foregroundColor(.secondary)
            Button("New Bottle…") { model.showNewBottle = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sheets

struct NewBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: BottleStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var name = "My Games"
    @State private var version: WindowsVersion = .win10
    @State private var graphics: GraphicsBackend = SystemInfo.current.canUseDXVK ? .dxvk : .wined3dGL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.bold())
            Text("A bottle is an isolated Windows environment (C: drive, registry, installed programs). Use separate bottles for programs that need different settings.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                Picker("Windows version", selection: $version) {
                    ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                }
                Picker("Graphics", selection: $graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                }
            }
            if !SystemInfo.current.canUseDXVK {
                Label("No Metal 2 (Mac2 family) GPU detected, so DXVK/MoltenVK won't work. Use WineD3D.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    var settings = BottleSettings()
                    settings.windowsVersion = version
                    settings.graphics = graphics
                    let bottleName = name
                    presentationMode.wrappedValue.dismiss()
                    Task {
                        if let bottle = await store.create(name: bottleName, settings: settings) {
                            model.selection = .bottle(bottle.url)
                        } else {
                            model.alert = "Couldn't create the bottle folder."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct RunFileSheet: View {
    let files: [URL]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: BottleStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var target: URL?
    @State private var arguments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run Windows Program").font(.title2.bold())
            ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.headline) }
            if store.bottles.isEmpty {
                Text("You need a bottle first.").foregroundColor(.secondary)
            } else {
                Form {
                    Picker("Bottle", selection: $target) {
                        ForEach(store.bottles) { Text($0.meta.name).tag(Optional($0.url)) }
                    }
                    TextField("Arguments (optional)", text: $arguments)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                if store.bottles.isEmpty {
                    Button("New Bottle…") { close(); model.showNewBottle = true }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Run") {
                        guard let url = target, let bottle = store.bottle(for: url) else { return }
                        model.lastBottleURL = url
                        model.selection = .bottle(url)
                        let args = splitArguments(arguments)
                        let files = self.files
                        Task { for file in files { await bottle.launch(file, arguments: args) } }
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.flatMap { store.bottle(for: $0)?.isReady } != true)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            target = store.bottles.first { $0.url == model.lastBottleURL }?.url ?? store.bottles.first?.url
        }
    }

    private func close() {
        model.filesToOpen = []
        presentationMode.wrappedValue.dismiss()
    }
}
