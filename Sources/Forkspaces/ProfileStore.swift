import Foundation
import AppKit
import Darwin

struct ProfileStore: Sendable {
    let locations: Locations
    let builder: BundleBuilder
    var registry: URL { locations.data.appendingPathComponent("profiles.json") }

    func load() throws -> [Profile] {
        try rejectSymlink(locations.data)
        guard fileManager.fileExists(atPath: registry.path) else { return [] }
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: registry))
        guard Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count else { throw Failure("Duplicate spaces in profiles.json.") }
        for profile in profiles {
            guard validID(profile.id), try validateName(profile.name) == profile.name, validColor(profile.color), try validateInitial(profile.initial ?? "") == profile.initial else { throw Failure("Invalid space record. profiles.json was not changed.") }
        }
        return profiles
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try rejectSymlink(locations.data)
        try rejectSymlink(locations.apps)
        try ensureDirectory(locations.data)
        try ensureDirectory(locations.apps)
        let fd = Darwin.open(locations.data.appendingPathComponent("manager.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Cannot lock space registry.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another Forkspaces operation is in progress.") }
        return try body()
    }

    func save(_ profiles: [Profile]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: registry, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
    }

    func create(name: String, color: String, initial: String = "", icon: IconChange = .keep, source: DataSource? = nil, fault: () throws -> Void = {}) throws -> Profile {
        try locked {
            var profiles = try load()
            let name = try validateName(name)
            let initial = try validateInitial(initial)
            guard validColor(color) else { throw Failure("Choose a space color.") }
            guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw Failure("A space with that name already exists.") }
            let slug = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let id = (slug.isEmpty ? "space" : slug) + "-" + UUID().uuidString.prefix(8).lowercased()
            let info = try readPlist(builder.source.appendingPathComponent("Contents/Info.plist"))
            let p = Profile(id: id, name: name, color: color, sourceVersion: info["CFBundleShortVersionString"] as? String ?? "unknown", createdAt: Date(), initial: initial)
            guard !fileManager.fileExists(atPath: locations.app(p).path) else { throw Failure("The application path already exists; it was not overwritten.") }
            let data = locations.storage(p)
            try rejectSymlink(data)
            guard !fileManager.fileExists(atPath: data.path) else { throw Failure("The space data path already exists; it was not overwritten.") }
            if let source {
                // Copy into a staging folder so a failed copy never leaves a half profile behind.
                let stage = locations.data.appendingPathComponent("profiles/.creating-\(UUID().uuidString)")
                try ensureDirectory(stage.deletingLastPathComponent())
                do { try copyData(from: source, to: stage, id: p.id); try fileManager.moveItem(at: stage, to: data) }
                catch { try? fileManager.removeItem(at: stage); throw error }
            } else {
                try ensureDirectory(data)
                try Data(p.id.utf8).write(to: data.appendingPathComponent(spaceMarker), options: .atomic)
                try seedConfig(data)
            }
            do {
                try writeIcon(icon, p)
                try install(p, replacing: nil)
                profiles.append(p)
                do { try fault(); try save(profiles) }
                catch { try? fileManager.removeItem(at: locations.app(p)); throw error }
            } catch {
                // A copied profile is only a copy: remove it so no partial profile remains. The source was never written.
                if source != nil { try? fileManager.removeItem(at: data); throw error }
                // Fresh storage only; preserve failed attempts for inspection rather than deleting data.
                let failed = locations.data.appendingPathComponent("Backups/failed-\(UUID().uuidString)")
                try? ensureDirectory(failed.deletingLastPathComponent())
                try? fileManager.moveItem(at: data, to: failed)
                throw error
            }
            return p
        }
    }

    /// New ID, data folder, bundle ID and launcher; Claude data, color, initial and custom icon are copied.
    func duplicate(_ p: Profile, name: String, fault: () throws -> Void = {}) throws -> Profile {
        let icon = (try? Data(contentsOf: locations.customIcon(p))).map(IconChange.custom) ?? .keep
        return try create(name: name, color: p.color, initial: p.initial ?? "", icon: icon, source: .profile(p), fault: fault)
    }

    func optimizeCowork(_ p: Profile) throws -> Int64 {
        try locked {
            guard try load().contains(p) else { throw Failure("The space changed. Reload and try again.") }
            return try withStoppedProfile(p) { try optimizeCoworkStorage(locations.storage(p), force: true) }
        }
    }

    func withStoppedProfile<T>(_ p: Profile, _ body: () throws -> T) throws -> T {
        guard runningApps(p, at: locations.app(p)).isEmpty else { throw Failure("Stop \(p.name) before editing, rebuilding or deleting it.") }
        let path = locations.storage(p)
        try rejectSymlink(path)
        guard (try? String(contentsOf: path.appendingPathComponent(spaceMarker), encoding: .utf8)) == p.id else { throw Failure("Space data ownership could not be verified.") }
        let fd = Darwin.open(path.appendingPathComponent(spaceLock).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Cannot check space lock.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("\(p.name) is running or starting. Close it before continuing.") }
        return try body()
    }

    /// A rename (or explicit rebuild) re-clones Claude. Icon/color/initial changes only rewrite the launcher icon.
    /// Claude data is never touched here.
    func update(_ old: Profile, name: String, color: String, initial: String? = nil, icon: IconChange = .keep, rebuild: Bool = false) throws -> Profile {
        try locked {
            var profiles = try load()
            guard let index = profiles.firstIndex(where: { $0.id == old.id }), profiles[index] == old else { throw Failure("The space changed. Reload and try again.") }
            let name = try validateName(name)
            let initial = try initial.map(validateInitial) ?? old.initial
            guard validColor(color), !profiles.contains(where: { $0.id != old.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw Failure("Choose a unique name and a valid color.") }
            return try withStoppedProfile(old) {
                var changed = old; changed.name = name; changed.color = color; changed.initial = initial
                let iconFile = locations.customIcon(old)
                let previousIcon = try? Data(contentsOf: iconFile)
                try writeIcon(icon, old)
                do {
                    if rebuild || name != old.name {
                        let info = try readPlist(builder.source.appendingPathComponent("Contents/Info.plist"))
                        changed.sourceVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
                        changed.validation = "needs interactive validation"
                        try install(changed, replacing: old) { profiles[index] = changed; try save(profiles) }
                    } else {
                        try refreshIcon(changed)
                        profiles[index] = changed
                        do { try save(profiles) } catch { try? restoreIcon(previousIcon, iconFile); try? refreshIcon(old); throw error }
                    }
                } catch { try? restoreIcon(previousIcon, iconFile); throw error }
                return changed
            }
        }
    }

    func writeIcon(_ change: IconChange, _ p: Profile) throws {
        let file = locations.customIcon(p)
        switch change {
        case .keep: return
        case .reset: if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
        case .custom(let png):
            try ensureDirectory(file.deletingLastPathComponent())
            try png.write(to: file, options: .atomic)
        }
    }

    private func restoreIcon(_ previous: Data?, _ file: URL) throws {
        if let previous { try previous.write(to: file, options: .atomic) }
        else if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
    }

    /// Rewrites only the launcher's .icns and re-seals the outer bundle signature.
    func refreshIcon(_ p: Profile) throws {
        let app = locations.app(p)
        guard ownedApp(app, p) else { throw Failure("Space application is missing or changed. Use Rebuild from Claude.") }
        try makeProfileIcon(p, data: locations.storage(p), at: app.appendingPathComponent("Contents/Resources/Forkspaces.icns"))
        try builder.codesign(app)
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        notifyFinder(app)
    }

    func notifyFinder(_ app: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        // LaunchServices registration is best effort outside a graphical session.
        _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        NSWorkspace.shared.noteFileSystemChanged(app.deletingLastPathComponent().path)
    }

    // MARK: Data copy. Claude data is an opaque folder: copied whole, never parsed, the source is only read.

    func directory(_ source: DataSource) -> URL {
        switch source {
        case .original: return locations.original
        case .profile(let p): return locations.storage(p)
        case .archive(let url): return url
        }
    }

    /// Apps that must quit before their data can be copied consistently (SQLite/LevelDB/IndexedDB).
    func apps(using source: DataSource) -> [NSRunningApplication] {
        switch source {
        case .original:
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").filter {
                $0.bundleURL?.standardizedFileURL == builder.source.standardizedFileURL
            }
        case .profile(let p): return runningApps(p, at: locations.app(p))
        case .archive: return []
        }
    }

    func copyData(from source: DataSource, to destination: URL, id: String) throws {
        let origin = directory(source)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: origin.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure("\(source.name) data was not found at \(origin.path).") }
        guard !fileManager.fileExists(atPath: destination.path) else { throw Failure("The copy destination already exists.") }
        var lock: Int32?
        if case .profile(let p) = source {
            guard (try? String(contentsOf: origin.appendingPathComponent(spaceMarker), encoding: .utf8)) == p.id else { throw Failure("Source space ownership could not be verified.") }
            // Holding the launcher lock keeps the source from starting mid-copy. The source is not written.
            lock = try holdLock(origin.appendingPathComponent(spaceLock), busy: "Quit \(p.name) before copying its data.")
        }
        defer { lock.map(releaseLock) }
        guard apps(using: source).isEmpty else { throw Failure("Quit \(source.name) before copying its data.") }
        // APFS clone: independent files, copy-on-write blocks, metadata and permissions preserved. Never hardlink or move.
        do { try run("/bin/cp", ["-cpR", origin.path, destination.path]) }
        catch {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try run("/usr/bin/ditto", [origin.path, destination.path])
        }
        // Desktop stores the session list in userData, but Code transcripts live separately.
        // Copy the opaque projects tree into the config root used by our launcher.
        if case .original = source {
            let projects = locations.originalCode.appendingPathComponent("projects")
            if fileManager.fileExists(atPath: projects.path) {
                let code = destination.appendingPathComponent("ClaudeCode")
                try ensureDirectory(code)
                try run("/usr/bin/ditto", [projects.path, code.appendingPathComponent("projects").path])
            }
        }
        // Forkspaces' own files and Chromium instance locks belong to the source, not the copy.
        for name in [spaceMarker, spaceLock, "icon", "SingletonLock", "SingletonSocket", "SingletonCookie"] {
            let item = destination.appendingPathComponent(name)
            if (try? fileManager.attributesOfItem(atPath: item.path)) != nil { try fileManager.removeItem(at: item) }
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try Data(id.utf8).write(to: destination.appendingPathComponent(spaceMarker), options: .atomic)
        try seedConfig(destination)
    }

    /// Adds Forkspaces' update/deep-link guards; keeps every other key (e.g. MCP servers) from the copied config.
    func seedConfig(_ dir: URL) throws {
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any] = [:], original: [String: Any]?
        if let data = try? Data(contentsOf: url) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            config = existing; original = existing
        }
        config["disableAutoUpdates"] = true
        config["disableDeepLinkRegistration"] = true
        config["autoUpdate"] = (config["autoUpdate"] as? [String: Any] ?? [:]).merging(["disabled": true]) { $1 }
        config["authentication"] = (config["authentication"] as? [String: Any] ?? [:]).merging(["disableDeepLinks": true]) { $1 }
        // Leave an already-guarded config byte-for-byte as copied.
        if let original, NSDictionary(dictionary: original).isEqual(to: config) { return }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: url, options: .atomic)
    }

    /// Replaces the destination's Claude data with a copy of the source. Name, ID, color, icon and launcher are kept.
    /// The previous data is kept in Backups; any failure restores it. `fault` exists for rollback tests.
    func importData(into p: Profile, from source: DataSource, fault: () throws -> Void = {}) throws -> URL {
        try locked {
            guard try load().contains(p) else { throw Failure("The space changed. Reload and try again.") }
            if case .profile(let s) = source, s.id == p.id { throw Failure("Choose a different source space.") }
            return try withStoppedProfile(p) {
                let live = locations.storage(p)
                let stage = locations.data.appendingPathComponent("profiles/.import-\(UUID().uuidString)")
                do {
                    try copyData(from: source, to: stage, id: p.id)
                    let icon = live.appendingPathComponent("icon")
                    if fileManager.fileExists(atPath: icon.path) { try fileManager.copyItem(at: icon, to: stage.appendingPathComponent("icon")) }
                } catch { try? fileManager.removeItem(at: stage); throw error }
                let backup = locations.data.appendingPathComponent("Backups/import-\(p.id)-\(UUID().uuidString)")
                do {
                    try ensureDirectory(backup)
                    try JSONEncoder().encode(p).write(to: backup.appendingPathComponent("space.json"))
                    try fileManager.moveItem(at: live, to: backup.appendingPathComponent("data"))
                } catch { try? fileManager.removeItem(at: stage); throw error }
                do {
                    try fault()
                    try fileManager.moveItem(at: stage, to: live)
                } catch {
                    try? fileManager.removeItem(at: stage)
                    guard (try? fileManager.moveItem(at: backup.appendingPathComponent("data"), to: live)) != nil else {
                        throw Failure("Import failed and the previous data could not be moved back. It is safe in \(backup.path).")
                    }
                    try? fileManager.removeItem(at: backup)
                    throw Failure("Import failed; \(p.name) data was restored. \(error.localizedDescription)")
                }
                return backup
            }
        }
    }

    // MARK: Export. A password-encrypted disk image: space.json (name, color, initial) and data/ (Claude data and icon).

    /// The space is only read. The image contains its active sign-in, so a password is required.
    func export(_ p: Profile, to destination: URL, password: String) throws {
        guard !password.isEmpty else { throw Failure("Choose a password for the export.") }
        try locked {
            guard try load().contains(p) else { throw Failure("The space changed. Reload and try again.") }
            let stage = locations.data.appendingPathComponent(".export-\(UUID().uuidString)")
            try ensureDirectory(stage)
            defer { try? fileManager.removeItem(at: stage) }
            let data = stage.appendingPathComponent("data")
            try copyData(from: .profile(p), to: data, id: p.id)
            let icon = locations.customIcon(p)
            if fileManager.fileExists(atPath: icon.path) {
                try ensureDirectory(data.appendingPathComponent("icon"))
                try fileManager.copyItem(at: icon, to: data.appendingPathComponent("icon/custom.png"))
            }
            try JSONEncoder().encode(p).write(to: stage.appendingPathComponent("space.json"))
            try run("/usr/bin/hdiutil", ["create", "-quiet", "-ov", "-encryption", "AES-256", "-stdinpass", "-fs", "APFS", "-format", "UDZO",
                                         "-volname", "Forkspaces Export", "-srcfolder", stage.path, destination.path], input: Data(password.utf8))
        }
    }

    /// Creates a new space (new ID) from an export. The file is untrusted: appearance is validated and links are rejected.
    func importArchive(_ archive: URL, password: String) throws -> Profile {
        let mount = locations.data.appendingPathComponent(".mount-\(UUID().uuidString)")
        try ensureDirectory(mount)
        do {
            try run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-stdinpass", "-mountpoint", mount.path, archive.path],
                    input: Data(password.utf8))
        } catch { try? fileManager.removeItem(at: mount); throw Failure("Could not open the export. Check the password and that the file is a Forkspaces export.") }
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])) != nil { try? fileManager.removeItem(at: mount) }
        }
        let data = mount.appendingPathComponent("data")
        guard let saved = try? JSONDecoder().decode(Profile.self, from: Data(contentsOf: mount.appendingPathComponent("space.json"))),
              (try? fileManager.destinationOfSymbolicLink(atPath: data.path)) == nil else { throw Failure("This file is not a Forkspaces export.") }
        for case let url as URL in fileManager.enumerator(at: data, includingPropertiesForKeys: [.isSymbolicLinkKey]) ?? .init()
            where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw Failure("This export contains symbolic links and was not imported.")
        }
        let base = try validateName(saved.name), taken = Set(try load().map { $0.name.lowercased() })
        let name = ([base] + (2...99).map { "\(base.prefix(44)) \($0)" }).first { !taken.contains($0.lowercased()) } ?? base
        let icon = (try? Data(contentsOf: data.appendingPathComponent("icon/custom.png"))).map(IconChange.custom) ?? .keep
        return try create(name: name, color: saved.color, initial: saved.initial ?? "", icon: icon, source: .archive(data))
    }

    func install(_ p: Profile, replacing old: Profile?, commit: () throws -> Void = {}) throws {
        let stage = locations.apps.appendingPathComponent(".build-\(UUID().uuidString)")
        try ensureDirectory(stage)
        defer { try? fileManager.removeItem(at: stage) }
        let built = stage.appendingPathComponent(p.appName)
        let destination = locations.app(p)
        if fileManager.fileExists(atPath: destination.path), !(old.map { locations.app($0) == destination && ownedApp(destination, $0) } ?? false) {
            throw Failure("An unrelated app occupies the destination. Nothing was overwritten.")
        }
        try builder.build(p, data: locations.storage(p), destination: built)
        let previous = stage.appendingPathComponent("Previous.app")
        if let old {
            guard ownedApp(locations.app(old), old) else { throw Failure("The existing space app has changed or is missing.") }
            try fileManager.moveItem(at: locations.app(old), to: previous)
        }
        do {
            try fileManager.moveItem(at: built, to: destination)
            try commit()
        } catch {
            if ownedApp(destination, p) { try? fileManager.removeItem(at: destination) }
            if let old, fileManager.fileExists(atPath: previous.path) { try? fileManager.moveItem(at: previous, to: locations.app(old)) }
            throw error
        }
        notifyFinder(destination)
    }

    func delete(_ p: Profile) throws -> URL {
        try locked {
            var profiles = try load()
            guard profiles.contains(p), ownedApp(locations.app(p), p) else { throw Failure("Space changed or is not owned by Forkspaces.") }
            return try withStoppedProfile(p) {
                let backup = locations.data.appendingPathComponent("Backups/\(p.id)-\(UUID().uuidString)")
                try ensureDirectory(backup)
                try JSONEncoder().encode(p).write(to: backup.appendingPathComponent("space.json"))
                let data = locations.storage(p), app = locations.app(p)
                try fileManager.moveItem(at: data, to: backup.appendingPathComponent("data"))
                do {
                    try fileManager.moveItem(at: app, to: backup.appendingPathComponent(p.appName))
                    do { profiles.removeAll { $0.id == p.id }; try save(profiles) }
                    catch { try? fileManager.moveItem(at: backup.appendingPathComponent(p.appName), to: app); throw error }
                } catch { try? fileManager.moveItem(at: backup.appendingPathComponent("data"), to: data); throw error }
                return backup
            }
        }
    }
}
