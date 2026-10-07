import SwiftUI
import AppKit
import Combine

// Use the property wrapper, not the SDK 27 macro (keeps builds compatible with macOS 13).
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class Model: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var running = Set<String>()
    @Published var busy: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var routingActive = false
    @Published var icons: [String: NSImage] = [:]
    @Published var quitRequest: QuitRequest?
    @Published var claudeVersion: String?
    @Published var sizes: [String: Int64] = [:]
    let store = ProfileStore(locations: .standard,
                             builder: BundleBuilder(resources: Bundle.main.resourceURL!, source: officialApp))
    var routing: LoginRouting { LoginRouting(root: store.locations.data) }
    var detected: Bool { fileManager.fileExists(atPath: officialApp.path) }
    /// Spaces built from an older Claude than the one in /Applications. Local comparison only.
    var outdated: [Profile] {
        guard let claudeVersion else { return [] }
        return profiles.filter { $0.sourceVersion.compare(claudeVersion, options: .numeric) == .orderedAscending }
    }

    init() { reload() }
    func reload() {
        do { profiles = try store.load() }
        catch { self.error = error.localizedDescription }
        claudeVersion = (try? readPlist(officialApp.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
        icons = Dictionary(uniqueKeysWithValues: profiles.map { p in
            (p.id, iconPreview(initial: p.iconInitial, color: p.color, image: NSImage(contentsOf: store.locations.customIcon(p))))
        })
        refreshStatus()
        let folders = profiles.map { ($0.id, store.locations.storage($0)) }
        Task {
            sizes = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: folders.map { ($0.0, diskUsage($0.1)) })
            }.value
        }
    }
    func refreshStatus() {
        running = Set(profiles.filter { !runningApps($0, at: store.locations.app($0)).isEmpty }.map(\.id))
        routingActive = routing.isActive
    }
    func perform(_ label: String, work: @escaping @Sendable () throws -> String?) {
        guard busy == nil else { return }
        busy = label
        Task {
            do { notice = try await Task.detached(priority: .userInitiated) { try work() }.value }
            catch { self.error = error.localizedDescription }
            busy = nil; reload()
        }
    }
    func save(_ old: Profile?, _ e: ProfileEdit) {
        let store = store
        if let old {
            perform("Updating \(old.name)…") {
                _ = try store.update(old, name: e.name, color: e.color, initial: e.initial, icon: e.icon)
                return nil
            }
        } else {
            performWithSourceClosed(e.source, e.source == nil ? "Creating space…" : "Copying \(e.source!.name) data and creating space…") {
                _ = try store.create(name: e.name, color: e.color, initial: e.initial, icon: e.icon, source: e.source)
                return nil
            }
        }
    }
    func rebuild(_ p: Profile) {
        let store = store
        perform("Rebuilding \(p.name)…") { _ = try store.update(p, name: p.name, color: p.color, rebuild: true); return nil }
    }
    func optimizeCowork(_ p: Profile) {
        let store = store
        perform("Optimizing Cowork storage for \(p.name)…") {
            let shared = try store.optimizeCowork(p)
            return shared > 0
                ? "Cowork images now share \(ByteCountFormatter.string(fromByteCount: shared, countStyle: .file)) of matching blocks with another space. Each space keeps its own data. Already-shared blocks are included; APFS snapshots may delay free-space recovery."
                : "No matching Cowork images were available. Close the other spaces and try again after Cowork has been installed in both."
        }
    }
    /// Rebuilds stopped outdated spaces one by one; data is kept. Running spaces are skipped.
    func rebuildAll() {
        let store = store, targets = outdated.filter { !running.contains($0.id) }
        let skipped = outdated.filter { running.contains($0.id) }.map(\.name)
        perform("Rebuilding \(targets.count) spaces…") {
            var failed: [String] = []
            for p in targets {
                do { _ = try store.update(p, name: p.name, color: p.color, rebuild: true) }
                catch { failed.append("\(p.name): \(error.localizedDescription)") }
            }
            var lines = ["Rebuilt \(targets.count - failed.count) of \(targets.count) spaces. Their data was kept."]
            if !skipped.isEmpty { lines.append("Skipped (running): \(skipped.joined(separator: ", ")). Stop them and rebuild again.") }
            if !failed.isEmpty { throw Failure((lines + failed).joined(separator: "\n")) }
            return lines.joined(separator: "\n")
        }
    }
    func duplicate(_ p: Profile, name: String) {
        let store = store
        performWithSourceClosed(.profile(p), "Duplicating \(p.name)…", purpose: "duplicated", confirm: "Close and Duplicate") {
            "\(try store.duplicate(p, name: name).name) created successfully."
        }
    }
    func importData(_ p: Profile, from source: DataSource) {
        let store = store
        performWithSourceClosed(source, "Importing \(source.name) data into \(p.name)…") {
            let backup = try store.importData(into: p, from: source)
            return "\(p.name) now uses a copy of \(source.name) data. Its previous data is kept in \(backup.path)."
        }
    }
    func exportSpace(_ p: Profile, to url: URL, password: String) {
        let store = store
        performWithSourceClosed(.profile(p), "Exporting \(p.name)…", purpose: "exported", confirm: "Close and Export") {
            try store.export(p, to: url, password: password)
            return "\(p.name) was exported to \(url.lastPathComponent). Anyone with this file and its password can use the space's sign-in."
        }
    }
    func importSpace(_ archive: URL, password: String) {
        let store = store
        perform("Importing \(archive.lastPathComponent)…") { "\(try store.importArchive(archive, password: password).name) was imported." }
    }
    /// Copying open SQLite/LevelDB/IndexedDB storage is unsafe; ask before quitting the source.
    func performWithSourceClosed(_ source: DataSource?, _ label: String, purpose: String = "copied", confirm: String = "Close and Continue",
                                 work: @escaping @Sendable () throws -> String?) {
        guard let source, case let apps = store.apps(using: source), !apps.isEmpty else { return perform(label, work: work) }
        quitRequest = QuitRequest(name: source.name, apps: apps, label: label, title: "\"\(source.name)\" needs to be closed before it can be \(purpose).",
                                  message: "Its data can only be copied safely while it is closed. Forkspaces will ask only this app to quit normally (no force quit), wait, then copy. Its data is not changed and it is not reopened.",
                                  confirm: confirm, work: work)
    }
    func quitAndContinue() {
        guard let r = quitRequest, busy == nil else { return }
        quitRequest = nil
        busy = "Waiting for \(r.name) to quit…"
        Task {
            r.apps.forEach { $0.terminate() }
            for _ in 0..<300 where !r.apps.allSatisfy(\.isTerminated) { try? await Task.sleep(nanoseconds: 100_000_000) }
            busy = nil
            guard r.apps.allSatisfy(\.isTerminated) else {
                error = "\(r.name) did not quit. Nothing was copied; close it yourself and try again."
                return refreshStatus()
            }
            // Give helper processes a moment to flush storage after the main process exits.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            perform(r.label, work: r.work)
        }
    }
    func open(_ p: Profile) {
        guard busy == nil else { return }
        busy = "Opening \(p.name)…"
        Task {
            do { try await openProfile(p, at: store.locations.app(p)) }
            catch { self.error = error.localizedDescription }
            busy = nil; refreshStatus()
            // LaunchServices acceptance is not proof that the Electron child stayed alive.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refreshStatus()
            if !running.contains(p.id) { error = "\(p.name) did not remain running. Try Rebuild from Claude. Your space data was preserved." }
        }
    }
    func stop(_ p: Profile, restart: Bool = false) {
        guard busy == nil else { return }
        busy = restart ? "Restarting \(p.name)…" : "Stopping \(p.name)…"
        Task {
            do {
                try await stopProfile(p, at: store.locations.app(p))
                if restart { try await openProfile(p, at: store.locations.app(p)) }
            } catch { self.error = error.localizedDescription }
            busy = nil; refreshStatus()
        }
    }
    func delete(_ p: Profile) {
        let store = store
        perform("Archiving \(p.name)…") {
            let path = try store.delete(p)
            return "Space removed. Its app and data are preserved in \(path.path)."
        }
    }
    func route(_ p: Profile) {
        do { try routing.select(p, app: store.locations.app(p)); routingActive = true }
        catch { self.error = error.localizedDescription }
    }
    func restoreRoute() {
        do { try routing.restore(); routingActive = false }
        catch { self.error = error.localizedDescription }
    }
}

@main
struct ForkspacesApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("Forkspaces") {
            ContentView(model: model)
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About Forkspaces", action: showAbout) }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Forkspaces Help") {
                    if let url = Bundle.main.url(forResource: "Help", withExtension: "html") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

@MainActor func showAbout() {
    let repository = Bundle.main.object(forInfoDictionaryKey: "ForkspacesRepositoryURL") as? String ?? ""
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    let credits = NSMutableAttributedString(string: "Isolated spaces for desktop apps on macOS.\nCreated by Gustavo Maia\nSource-available · free for personal and internal business use\n", attributes: base)
    if let url = URL(string: repository), !repository.isEmpty {
        credits.append(NSAttributedString(string: repository.replacingOccurrences(of: "https://", with: "") + "\n", attributes: base.merging([.link: url]) { $1 }))
    }
    credits.append(NSAttributedString(string: "\nUnofficial project. Not affiliated with or endorsed by Anthropic.", attributes: base))
    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Forkspaces", .credits: credits])
    NSApp.activate(ignoringOtherApps: true)
}

struct ProfileEdit: Sendable {
    var name: String
    var color: String
    var initial: String
    var icon: IconChange
    var source: DataSource?
}

struct QuitRequest {
    let name: String
    let apps: [NSRunningApplication]
    let label: String
    let title: String
    let message: String
    let confirm: String
    let work: @Sendable () throws -> String?
}

struct ContentView: View {
    @ObservedObject var model: Model
    @ViewState private var editor: EditorTarget?
    @ViewState private var deleting: Profile?
    @ViewState private var importing: Profile?
    @ViewState private var duplicating: Profile?
    @ViewState private var login: Profile?
    @ViewState private var password: PasswordRequest?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Spaces").font(.largeTitle.bold())
                    Text(model.detected ? "Existing Claude installation detected" : "Install Claude in /Applications to create spaces")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: importSpace) { Label("Import…", systemImage: "square.and.arrow.down") }
                    .disabled(!model.detected || model.busy != nil).help("Create a space from an export")
                Button { editor = EditorTarget(profile: nil) } label: { Label("New Space", systemImage: "plus") }
                    .keyboardShortcut("n").disabled(!model.detected || model.busy != nil)
            }.padding(24)
            Divider()
            if let version = model.claudeVersion, case let outdated = model.outdated, !outdated.isEmpty {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("Claude was updated to \(version). \(outdated.count == 1 ? "1 space uses" : "\(outdated.count) spaces use") an older version.")
                    Spacer()
                    Button("Rebuild All") { model.rebuildAll() }
                        .disabled(model.busy != nil || outdated.allSatisfy { model.running.contains($0.id) })
                        .help("Rebuilds stopped spaces from Claude. Data is kept; running spaces are skipped.")
                }.font(.callout).padding(.horizontal, 24).padding(.vertical, 10)
                Divider()
            }
            if model.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.square.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("A separate space for each account").font(.title3.weight(.medium))
                    Text("Create Personal, Work or any other space.\nEach opens as its own macOS app.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("New Space") { editor = EditorTarget(profile: nil) }.disabled(!model.detected || model.busy != nil)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.profiles) { p in
                    let running = model.running.contains(p.id)
                    HStack(spacing: 14) {
                        Image(nsImage: model.icons[p.id] ?? iconPreview(initial: p.iconInitial, color: p.color, image: nil))
                            .resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.headline).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().fill(running ? Color.green : Color.secondary).frame(width: 6, height: 6)
                                Text(running ? "Running" : "Stopped").font(.caption).foregroundStyle(.secondary)
                                Text("· Claude \(p.sourceVersion)").font(.caption)
                                    .foregroundStyle(model.outdated.contains(p) ? Color.orange : Color.secondary)
                                if let size = model.sizes[p.id] {
                                    Text("· \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                        .help("Allocated file sizes, including APFS blocks shared with other spaces. This is not exclusive disk usage.")
                                }
                            }
                        }
                        Spacer()
                        if running { Button("Stop") { model.stop(p) } }
                        else { Button("Open") { model.open(p) } }
                        Menu {
                            Button("Open") { model.open(p) }
                            Button("Stop") { model.stop(p) }.disabled(!running)
                            Button("Restart") { model.stop(p, restart: true) }.disabled(!running)
                            Divider()
                            Button("Edit Space…") { editor = EditorTarget(profile: p) }.disabled(running)
                            Button("Duplicate Space…") { duplicating = p }
                            Button("Export Space…") { export(p) }
                            Button("Import Space Data…") { importing = p }.disabled(running)
                            Divider()
                            Button("Reveal Data Folder") { NSWorkspace.shared.open(model.store.locations.storage(p)) }
                            Button("Reveal Launcher") { NSWorkspace.shared.activateFileViewerSelecting([model.store.locations.app(p)]) }
                            Divider()
                            Button("Sign-in Help…") { login = p }
                            Button("Rebuild from Claude") { model.rebuild(p) }.disabled(running)
                            Button("Optimize Cowork Storage") { model.optimizeCowork(p) }.disabled(running)
                            Divider()
                            Button("Delete Space…", role: .destructive) { deleting = p }.disabled(running)
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 9).disabled(model.busy != nil)
                }.listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let busy = model.busy { HStack { ProgressView().controlSize(.small); Text(busy) } }
                else { Text("Everything runs locally · the original Claude is never modified").foregroundStyle(.secondary) }
                if model.routingActive {
                    HStack {
                        Text("Browser login routing is temporarily changed.").font(.caption)
                        Spacer()
                        Button("Restore") { model.restoreRoute() }
                    }
                }
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Forkspaces v\(version)").font(.caption).foregroundStyle(.secondary)
                }
            }.font(.callout).padding(16)
        }
        .onReceive(timer) { _ in model.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.busy == nil { model.reload() }
        }
        .sheet(item: $editor) { target in
            ProfileEditor(profile: target.profile, profiles: model.profiles, store: model.store, originalAvailable: fileManager.fileExists(atPath: model.store.locations.original.path)) {
                model.save(target.profile, $0)
            }
        }
        .sheet(item: $duplicating) { p in
            DuplicateSheet(source: p, icon: model.icons[p.id], taken: Set(model.profiles.map { $0.name.lowercased() })) { model.duplicate(p, name: $0) }
        }
        .sheet(item: $importing) { p in
            ImportSheet(target: p, profiles: model.profiles, originalAvailable: fileManager.fileExists(atPath: model.store.locations.original.path)) {
                model.importData(p, from: $0)
            }
        }
        .sheet(item: $password) { PasswordSheet(request: $0) }
        .sheet(item: $login) { p in
            VStack(alignment: .leading, spacing: 18) {
                Text("Sign in to \(p.name)").font(.title2.bold())
                Text("Open this space and use Claude’s normal login. Choose the account for this space in the browser; switch browser accounts if needed.")
                Text("If the browser callback opens the wrong Claude app, route browser login to this space and repeat login. Complete one login at a time, then restore the previous routing.").foregroundStyle(.secondary)
                Text("No login link, password, cookie or token is read by Forkspaces.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Route browser login here") { model.route(p) }
                    Button("Restore previous routing") { model.restoreRoute() }.disabled(!model.routingActive)
                }
                HStack { Button("Open \(p.name)") { model.open(p) }; Spacer(); Button("Done") { login = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 490)
        }
        .alert("Could not complete the operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Done", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .alert(model.quitRequest?.title ?? "", isPresented: Binding(get: { model.quitRequest != nil }, set: { if !$0 { model.quitRequest = nil } })) {
            Button(model.quitRequest?.confirm ?? "Close and Continue") { model.quitAndContinue() }
            Button("Cancel", role: .cancel) { model.quitRequest = nil }
        } message: { Text(model.quitRequest?.message ?? "") }
        .confirmationDialog("Delete \(deleting?.name ?? "profile")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Archive and Delete Space", role: .destructive) { if let p = deleting { model.delete(p) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its app and data will be moved to Forkspaces/Backups. The original Claude and other spaces are not changed.") }
    }
}

extension ContentView {
    private func export(_ p: Profile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.diskImage]
        panel.nameFieldStringValue = "\(p.name) Space.dmg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        password = PasswordRequest(title: "Export \"\(p.name)\"", confirm: "Export", twice: true,
                                   message: "The export contains this space's Claude data, including its active sign-in. It is encrypted with this password; anyone with the file and the password can use the account. On another Mac you may need to sign in again.") {
            model.exportSpace(p, to: url, password: $0)
        }
    }

    private func importSpace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.message = "Choose a space exported from Forkspaces."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        password = PasswordRequest(title: "Import \"\(url.deletingPathExtension().lastPathComponent)\"", confirm: "Import", twice: false,
                                   message: "A new space is created from this export. Your existing spaces are not changed.") {
            model.importSpace(url, password: $0)
        }
    }
}

struct PasswordRequest: Identifiable {
    let id = UUID()
    let title: String
    let confirm: String
    let twice: Bool
    let message: String
    let run: (String) -> Void
}

struct PasswordSheet: View {
    let request: PasswordRequest
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""
    @ViewState private var repeated = ""
    private var valid: Bool { !password.isEmpty && (!request.twice || password == repeated) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title).font(.title2.bold())
            Text(request.message).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            if request.twice { SecureField("Repeat Password", text: $repeated).textFieldStyle(.roundedBorder) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.confirm) { request.run(password); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(28).frame(width: 460)
    }
}

enum StartMode: Hashable { case empty, original, profile }

struct EditorTarget: Identifiable {
    let id = UUID()
    let profile: Profile?
}

struct ProfileEditor: View {
    let profile: Profile?
    let profiles: [Profile]
    let store: ProfileStore
    let originalAvailable: Bool
    let save: (ProfileEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var color: String
    @ViewState private var initial: String
    @ViewState private var image: NSImage?
    @ViewState private var icon = IconChange.keep
    @ViewState private var start = StartMode.empty
    @ViewState private var sourceID: String
    @ViewState private var problem: String?

    init(profile: Profile?, profiles: [Profile], store: ProfileStore, originalAvailable: Bool, save: @escaping (ProfileEdit) -> Void) {
        self.profile = profile; self.profiles = profiles; self.store = store; self.originalAvailable = originalAvailable; self.save = save
        _name = ViewState(initialValue: profile?.name ?? "")
        _color = ViewState(initialValue: profile?.color ?? profileColors[0])
        _initial = ViewState(initialValue: profile?.iconInitial ?? "")
        _image = ViewState(initialValue: profile.flatMap { NSImage(contentsOf: store.locations.customIcon($0)) })
        _sourceID = ViewState(initialValue: profiles.first?.id ?? "")
    }

    private var defaultInitial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
    private var source: DataSource? {
        switch start {
        case .empty: return nil
        case .original: return .original
        case .profile: return profiles.first { $0.id == sourceID }.map(DataSource.profile)
        }
    }
    private var valid: Bool {
        (try? validateName(name)) != nil && (try? validateInitial(initial)) != nil && (start != .profile || source != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(profile == nil ? "New Space" : "Edit Space").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: iconPreview(initial: initial.isEmpty ? defaultInitial : initial, color: color, image: image))
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Space Name", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Initial", text: $initial, prompt: Text(defaultInitial)).textFieldStyle(.roundedBorder).frame(width: 64)
                            .help("Letter shown on the generated icon")
                        Button("Choose Custom Icon…", action: chooseImage)
                        Button("Reset to Default Icon") { image = nil; icon = .reset; initial = defaultInitial }
                            .disabled(image == nil && (initial.isEmpty || initial == defaultInitial))
                    }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
            HStack(spacing: 12) {
                Text("Color")
                ForEach(profileColors, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(Color(nsColor: colorValue(value))).frame(width: 26, height: 26)
                            .overlay { if color == value { Image(systemName: "checkmark").foregroundStyle(.white) } }
                    }.buttonStyle(.plain).accessibilityLabel("Color \(value)")
                }
                ColorPicker("Custom color", selection: Binding(get: { Color(nsColor: colorValue(color)) },
                                                              set: { if let hex = hexValue(NSColor($0)) { color = hex } }), supportsOpacity: false)
                    .labelsHidden()
            }
            if profile == nil {
                Picker("Start with", selection: $start) {
                    Text("Empty Space").tag(StartMode.empty)
                    Text("Existing Claude Installation").tag(StartMode.original).disabled(!originalAvailable)
                    Text("Existing Space").tag(StartMode.profile).disabled(profiles.isEmpty)
                }
                if start == .profile {
                    Picker("Source space", selection: $sourceID) {
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                }
                Text(start == .empty
                     ? "A local copy of Claude will be prepared with its own icon and storage. The first build may take a minute."
                     : "Sign-in, history and settings are copied once. The source is only read, never changed, and the two stay independent afterwards. If the source is open you will be asked to quit it first.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if profile.map({ name.trimmingCharacters(in: .whitespaces) != $0.name }) == true {
                Text("Renaming rebuilds the space app. Claude data is kept.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(profile == nil ? "Create Space" : "Save") {
                    save(ProfileEdit(name: name, color: color, initial: initial == defaultInitial ? "" : initial, icon: icon, source: source)); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(28).frame(width: 520)
        // An initial that matched the old name keeps following the name.
        .onChange(of: defaultInitial) { [defaultInitial] newValue in
            if initial.isEmpty || initial == defaultInitial { initial = newValue }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.message = "Choose an image. It is cropped to a square and copied into the space."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let png = try squareIconPNG(from: url)
            image = NSImage(data: png); icon = .custom(png); problem = nil
        } catch { problem = error.localizedDescription }
    }
}

struct ImportSheet: View {
    let target: Profile
    let profiles: [Profile]
    let originalAvailable: Bool
    let run: (DataSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var choice = ""
    @ViewState private var confirming = false
    private var others: [Profile] { profiles.filter { $0.id != target.id } }
    private var source: DataSource? {
        choice == "original" ? (originalAvailable ? .original : nil) : others.first { $0.id == choice }.map(DataSource.profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Data into \(target.name)").font(.title2.bold())
            Picker("Import from", selection: $choice) {
                Text("Claude Desktop (original)").tag("original").disabled(!originalAvailable)
                ForEach(others) { Text($0.name).tag($0.id) }
            }
            Text("This replaces all Claude data in \(target.name): sign-in, history and settings. Its current data is backed up to Forkspaces/Backups first and restored automatically if the import fails.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The source is only read. Name, color, icon and launcher of \(target.name) are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Replace Data…", role: .destructive) { confirming = true }.disabled(source == nil)
            }
        }.padding(28).frame(width: 480)
        .onAppear { choice = originalAvailable ? "original" : others.first?.id ?? "" }
        .confirmationDialog("Replace all Claude data in \(target.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace with \(source?.name ?? "") Data", role: .destructive) { if let source { run(source) }; dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A backup of the current data is kept in Forkspaces/Backups.") }
    }
}

struct DuplicateSheet: View {
    let source: Profile
    let icon: NSImage?
    let taken: Set<String>
    let run: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String

    init(source: Profile, icon: NSImage?, taken: Set<String>, run: @escaping (String) -> Void) {
        self.source = source; self.icon = icon; self.taken = taken; self.run = run
        let base = "\(source.name) Copy"
        let free = ([base] + (2...99).map { "\(base) \($0)" }).first { !taken.contains($0.lowercased()) } ?? base
        _name = ViewState(initialValue: String(free.prefix(48)))
    }

    private var valid: Bool { (try? validateName(name)).map { !taken.contains($0.lowercased()) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Duplicate \"\(source.name)\"").font(.title2.bold())
            HStack(spacing: 14) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    Text("Icon and color are kept. Edit them later if you like.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Claude data, history, sign-in and settings are copied once. The copy gets its own app and storage; changes in one never affect the other.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Duplicate") { run(name); dismiss() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(28).frame(width: 440)
    }
}
