import SwiftUI
import Combine
import AppKit
import AppEnvCore
import UniformTypeIdentifiers

@MainActor final class Model: ObservableObject {
    @Published var environments: [AppEnvCore.Environment] = []
    @Published var selection: UUID?
    @Published var error: String?
    @Published var busy = false
    @Published var status = "Ready"
    let store: Store?
    init() {
        do { store = try Store() } catch { store = nil; self.error = error.localizedDescription }
        refresh()
    }
    var selected: AppEnvCore.Environment? { environments.first { $0.id == selection } }
    func refresh() {
        guard !busy, let store else { return }
        do {
            environments = try store.list()
            if selection == nil || !environments.contains(where: { $0.id == selection }) { selection = environments.first?.id }
        } catch {
            // A busy peer is transient. Storage corruption must remain visible.
            if !error.localizedDescription.contains("operation is in progress") { self.error = error.localizedDescription }
        }
    }
    func perform(_ label: String, _ action: () throws -> Void) {
        guard !busy else { return }
        do { try action(); status = label; refresh() } catch { self.error = error.localizedDescription }
    }
    func launch(_ environment: AppEnvCore.Environment, _ app: AppBinding, allowVersionChange: Bool = false) {
        guard !busy, let store else { return }
        busy = true; status = "Opening \(app.adapter.name)…"
        Task {
            do {
                _ = try await store.launch(environment.id.uuidString, adapter: app.adapter, allowVersionChange: allowVersionChange)
                status = "Opened \(app.adapter.name) in \(environment.name)"
            } catch { self.error = error.localizedDescription; status = "Launch needs attention" }
            busy = false; refresh()
        }
    }
    func stop(_ environment: AppEnvCore.Environment, adapter: Adapter? = nil, force: Bool = false) {
        guard !busy, let store else { return }
        busy = true; status = "Stopping apps…"
        Task {
            do { try await store.stop(environment.id.uuidString, adapter: adapter, force: force); status = "Stopped" }
            catch { self.error = error.localizedDescription; status = "Stop needs attention" }
            busy = false; refresh()
        }
    }
    func add(_ adapter: Adapter, environment: AppEnvCore.Environment, choose: Bool = false) {
        var url = adapter.installedURL
        if choose || url == nil {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.message = "Choose the official \(adapter.name) application."
            guard panel.runModal() == .OK else { return }; url = panel.url
        }
        perform("Added \(adapter.name)") { try store?.add(environment.id.uuidString, adapter: adapter, url: url) }
    }
    func export(_ environment: AppEnvCore.Environment) {
        guard let store else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "AppEnv-Backup.zip"
        panel.message = "This archive may contain signed-in sessions. Keep it private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Exporting…"
        Task {
            do {
                try await Task.detached { try store.export(environment.id.uuidString, to: url) }.value
                status = "Exported \(environment.name)"; NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription; status = "Export failed" }
            busy = false; refresh()
        }
    }
    func browseApps(_ environment: AppEnvCore.Environment) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to \(environment.name)"
        panel.message = "Choose Chrome, VS Code, or Codex (also named ChatGPT in newer builds). You can also press ⇧⌘G to enter an application path."
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls, to: environment)
    }
    func addFiles(_ urls: [URL], to environment: AppEnvCore.Environment) {
        guard !busy else { return }
        do {
            guard let store else { throw AppEnvError("Storage is unavailable.") }
            let count = try store.addApplicationFiles(environment.id.uuidString, urls: urls)
            selection = environment.id
            status = count == 0 ? "Apps already added to \(environment.name)" : "Added \(count) app\(count == 1 ? "" : "s") to \(environment.name)"
            refresh()
        } catch { self.error = error.localizedDescription; status = "Adding apps needs attention" }
    }
    func acceptDrop(_ providers: [NSItemProvider], into environment: AppEnvCore.Environment) -> Bool {
        guard !busy, !providers.isEmpty else { return false }
        busy = true; status = "Reading dropped apps…"
        Task {
            do {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error); return }
                            let url: URL?
                            if let value = item as? URL { url = value }
                            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                            else if let string = item as? String { url = URL(string: string) }
                            else { url = nil }
                            guard let url, url.isFileURL else {
                                continuation.resume(throwing: AppEnvError("Cannot read this drag. Drop an application from Finder.")); return
                            }
                            continuation.resume(returning: url)
                        }
                    }
                    urls.append(url)
                }
                busy = false
                addFiles(urls, to: environment)
            } catch { busy = false; self.error = error.localizedDescription; status = "Drop needs attention" }
        }
        return true
    }
}

private struct AppDropTarget: ViewModifier {
    @ObservedObject var model: Model
    let environment: AppEnvCore.Environment
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(targeted && !model.busy ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(targeted && !model.busy ? Color.accentColor.opacity(0.08) : .clear)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                model.acceptDrop(providers, into: environment)
            }
    }
}

@main struct AppEnvApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("AppEnv") { MainView(model: model) }
            .defaultSize(width: 940, height: 620)
        MenuBarExtra("AppEnv", systemImage: "square.stack.3d.up") {
            ForEach(model.environments) { env in
                Menu(env.name) {
                    ForEach(env.apps) { app in
                        Button("\(app.instance == nil ? "Open" : "Focus") \(app.adapter.name)") { model.launch(env, app) }
                    }
                    if env.isRunning { Divider(); Button("Stop apps") { model.stop(env) } }
                }
            }
            Divider()
            Button("Show AppEnv") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Button("Quit AppEnv") { NSApp.terminate(nil) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    @State private var editor: Editor?
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var forceAdapter: Adapter?
    @State private var versionApp: AppBinding?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    enum Editor: String, Identifiable { case create = "New Environment", rename = "Rename Environment", duplicate = "Duplicate Environment"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView {
            VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("ENVIRONMENTS") {
                    ForEach(model.environments) { env in
                        HStack {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(env.name).fontWeight(.medium)
                                Text("\(env.apps.count) apps · \(env.isRunning ? "Running" : "Stopped")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if env.isRunning { Circle().fill(.green).frame(width: 7, height: 7) }
                        }.padding(.vertical, 5)
                            .modifier(AppDropTarget(model: model, environment: env))
                            .help("Drop applications here to add them to \(env.name)")
                            .tag(env.id)
                    }
                }
            }
                Divider()
                Button { name = ""; editor = .create } label: { Label("New Environment", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).padding()
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 245)
        } detail: {
            if let env = model.selected { detail(env) }
            else {
                ContentUnavailableView {
                    Label("Your apps, separate spaces", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Create an environment for work, personal accounts, or testing. Run supported apps in several environments at once.")
                } actions: {
                    Button("Create Environment") { name = ""; editor = .create }.buttonStyle(.borderedProminent)
                }
            }
        }
        .disabled(model.busy)
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Native profiles").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 9).background(.bar)
        }
        .frame(minWidth: 760, minHeight: 500)
        .onReceive(timer) { _ in model.refresh() }
        .sheet(item: $editor) { mode in
            VStack(alignment: .leading, spacing: 18) {
                Text(mode.rawValue).font(.title2.bold())
                TextField("Environment name", text: $name).textFieldStyle(.roundedBorder).onSubmit { saveName(mode) }
                if mode == .duplicate { Text("Copies stored app data, including any saved sessions. Apps must be stopped.").font(.caption).foregroundStyle(.secondary) }
                HStack { Spacer(); Button("Cancel") { editor = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") { saveName(mode) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(24).frame(width: 390)
        }
        .alert("AppEnv needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Move this environment to Trash?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let env = model.selected { model.perform("Moved to Trash") { try model.store?.delete(env.id.uuidString) } }
            }
        } message: { Text("All managed profile data will be moved to Trash. Installed applications are kept.") }
        .confirmationDialog("Force stop this app? Unsaved work may be lost.", isPresented: Binding(get: { forceAdapter != nil }, set: { if !$0 { forceAdapter = nil } }), titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) {
                if let env = model.selected, let adapter = forceAdapter { model.stop(env, adapter: adapter, force: true) }; forceAdapter = nil
            }
        }
        .confirmationDialog("Allow this app version to use the profile?", isPresented: Binding(get: { versionApp != nil }, set: { if !$0 { versionApp = nil } }), titleVisibility: .visible) {
            Button("Allow and Open") {
                if let env = model.selected, let app = versionApp { model.launch(env, app, allowVersionChange: true) }; versionApp = nil
            }
        } message: { Text("App updates may migrate profile data. Duplicate the stopped environment first if you need a backup.") }
    }
    private func saveName(_ mode: Editor) {
        model.perform("Environment saved") {
            guard let store = model.store else { throw AppEnvError("Storage is unavailable.") }
            switch mode {
            case .create: model.selection = try store.create(name).id
            case .rename: if let env = model.selected { try store.rename(env.id.uuidString, to: name) }
            case .duplicate: if let env = model.selected { model.selection = try store.duplicate(env.id.uuidString, name: name).id }
            }
        }
        editor = nil
    }
    private func detail(_ env: AppEnvCore.Environment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(env.name).font(.largeTitle.bold())
                        Text("Independent profiles. Familiar apps.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Rename…") { name = env.name; editor = .rename }
                        Button("Duplicate…") { name = "\(env.name) Copy"; editor = .duplicate }.disabled(env.isRunning)
                        Button("Export…") { model.export(env) }.disabled(env.isRunning)
                        Button("Show Data in Finder") { if let store = model.store { NSWorkspace.shared.open(store.directory(env.id)) } }
                        Divider()
                        Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(env.isRunning)
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }.menuStyle(.borderlessButton).frame(width: 30)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                    Text("Profiles separate supported app data. Your macOS account, Keychain, permissions, and network remain shared. Cloud sync can reconnect data across profiles.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("Applications").font(.title3.bold()); Spacer()
                    if env.isRunning || env.apps.contains(where: { $0.adapter == .codex }) { Button("Stop All") { model.stop(env) } }
                    Menu {
                        Button("Browse for Apps…") { model.browseApps(env) }
                        Divider()
                        ForEach(Adapter.allCases) { adapter in
                            Button(adapter.name) { model.add(adapter, environment: env) }.disabled(env.apps.contains { $0.adapter == adapter })
                        }
                    } label: { Label("Add App", systemImage: "plus") }.fixedSize()
                }
                Label("Drag apps here or onto an environment. Or use Add App → Browse for Apps…", systemImage: "square.and.arrow.down")
                    .font(.callout).foregroundStyle(.secondary)
                if env.apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "app.dashed").font(.system(size: 38)).foregroundStyle(.secondary)
                        Text("Add your first app").font(.headline)
                        Text("Supports Chrome, VS Code, and Codex.").foregroundStyle(.secondary)
                        Button("Browse for Apps…") { model.browseApps(env) }
                        HStack { ForEach(Adapter.allCases) { adapter in Button("Add \(adapter.name)") { model.add(adapter, environment: env) } } }
                    }.frame(maxWidth: .infinity).padding(.vertical, 38)
                }
                ForEach(env.apps) { app in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: app.path) as NSURL) }
                            .help("Drag to another environment to add this app with a separate profile")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.adapter.name).font(.headline)
                            if app.adapter == .codex { Text("Separate local state · sign in within this environment").font(.caption).foregroundStyle(.secondary) }
                            Text(app.instance.map { "Running · PID \($0.pid)" } ?? "Stopped").font(.caption).foregroundStyle(app.instance == nil ? Color.secondary : Color.green)
                            if let version = app.lastVersion { Text("Last used version \(version)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if app.instance != nil { Button("Stop") { model.stop(env, adapter: app.adapter) } }
                        Button(app.instance == nil ? "Open" : "Focus") { model.launch(env, app) }.buttonStyle(.borderedProminent)
                        Menu {
                            Button("Choose App Location…") { model.add(app.adapter, environment: env, choose: true) }.disabled(app.instance != nil)
                            Button("Open Allowing Version Change…") { versionApp = app }.disabled(app.instance != nil)
                            if app.instance != nil || app.adapter == .codex { Button("Force Stop…", role: .destructive) { forceAdapter = app.adapter } }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                    }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                }
                Text("Opening an app again focuses its existing instance in this environment. Create another environment for another independent instance.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(30)
        }
        .modifier(AppDropTarget(model: model, environment: env))
    }
}
