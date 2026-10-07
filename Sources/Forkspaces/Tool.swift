import Foundation
import AppKit

@main
struct Tool {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure("Check failed: \(message)") }
    }
    /// Every regular file under a folder, by relative path, for before/after comparisons.
    static func snapshot(_ dir: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in fileManager.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) ?? .init() {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count))] = try? Data(contentsOf: url)
        }
        return result
    }
    static func verifySignature(_ app: URL) throws { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
    static func icns(_ p: Profile, _ store: ProfileStore) -> Data? { try? Data(contentsOf: store.locations.app(p).appendingPathComponent("Contents/Resources/Forkspaces.icns")) }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            if args.first == "icon", args.count == 2 {
                try makeAppIcon(at: URL(fileURLWithPath: args[1])); return
            }
            guard args.first == "integration", args.count == 2 else { throw Failure("Usage: ForkspacesTool integration <new-test-directory> | icon <output.icns>") }
            let root = URL(fileURLWithPath: args[1]).standardizedFileURL
            guard !fileManager.fileExists(atPath: root.path) else { throw Failure("Use a new test directory; existing data will not be touched.") }
            try require((try? validateName(" ../bad")) == nil, "reject traversal")
            try require((try? validateName("Work/Personal")) == nil, "reject slash")
            try require(!validID("../../original"), "reject invalid ID")
            // profiles.json written before optional fields (initial) existed must still load.
            let minimal = ##"[{"color":"#6688CC","createdAt":813013095.3,"id":"work","name":"Work","sourceVersion":"2.26454.0","validation":"needs interactive validation"}]"##
            let old = try JSONDecoder().decode([Profile].self, from: Data(minimal.utf8))
            try require(old[0].initial == nil && old[0].iconInitial == "W", "minimal space record")
            try require(validColor("#12AB9F") && !validColor("12AB9F") && !validColor("#12ab9f"), "color validation")
            try require((try? validateInitial("ABC")) == nil && (try validateInitial(" ")) == nil, "initial validation")
            print("Minimal profiles.json decodes")
            let fakeOriginal = root.appendingPathComponent("OriginalClaude")
            let store = ProfileStore(locations: Locations(data: root.appendingPathComponent("Data"), apps: root.appendingPathComponent("Applications"), original: fakeOriginal),
                                     builder: BundleBuilder(resources: resources, source: officialApp))
            let personal = try store.create(name: "Personal", color: profileColors[0])
            print("Created Personal")
            let work = try store.create(name: "Work", color: profileColors[1])
            print("Created Work")
            try require(personal.bundleID != work.bundleID, "unique bundle IDs")
            try require(store.locations.storage(personal) != store.locations.storage(work), "unique storage")
            do { _ = try store.create(name: "personal", color: profileColors[0]); throw Failure("Duplicate profile was accepted") }
            catch let e as Failure { guard e.message.contains("already exists") else { throw e } }
            let marker = store.locations.storage(work).appendingPathComponent("test-preserved.txt")
            try Data("not credentials".utf8).write(to: marker)
            try require(diskUsage(store.locations.storage(work)) >= Int64("not credentials".utf8.count), "disk usage counts space data")
            let renamed = try store.update(work, name: "Work Test", color: profileColors[2])
            try require(fileManager.fileExists(atPath: marker.path), "rebuild preserves storage")
            try require(!fileManager.fileExists(atPath: store.locations.app(work).path), "old app renamed")
            try require(ownedApp(store.locations.app(renamed), renamed), "renamed bundle identity")
            print("Renamed/recolored/rebuilt Work; storage preserved")
            let backup = try store.delete(renamed)
            try require(fileManager.fileExists(atPath: backup.appendingPathComponent("data/test-preserved.txt").path), "deletion backup")
            try require(!fileManager.fileExists(atPath: store.locations.app(renamed).path), "archived app removed from live folder")
            try require(try store.load().count == 1, "registry after archive")
            print("Archived Work with data and app intact")
            let second = try store.create(name: "Work", color: profileColors[1])
            try require(ownedApp(store.locations.app(personal), personal) && ownedApp(store.locations.app(second), second), "both final apps")
            // Custom icon: non-square PNG, cropped, copied into the profile, survives deletion of the original file.
            let picture = root.appendingPathComponent("picture.png")
            let wide = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try wide.representation(using: .png, properties: [:])!.write(to: picture)
            let png = try squareIconPNG(from: picture)
            try require(NSBitmapImageRep(data: png)?.pixelsWide == 1024 && NSBitmapImageRep(data: png)?.pixelsHigh == 1024, "square 1024 icon")
            try fileManager.removeItem(at: picture)
            let personalMarker = store.locations.storage(personal).appendingPathComponent("Cookies")
            try Data("personal opaque".utf8).write(to: personalMarker)
            let defaultIcon = icns(personal, store)
            let iconic = try store.update(personal, name: personal.name, color: personal.color, icon: .custom(png))
            try require(fileManager.fileExists(atPath: store.locations.customIcon(iconic).path), "custom icon stored in profile")
            try require(icns(iconic, store) != defaultIcon, "launcher icns replaced")
            try verifySignature(store.locations.app(iconic))
            try require(try String(contentsOf: personalMarker, encoding: .utf8) == "personal opaque", "icon change keeps data")
            let reloaded = try store.load().first { $0.id == personal.id }!
            try require(reloaded == iconic, "icon persisted in registry")
            let customIcns = icns(iconic, store)
            let recolored = try store.update(iconic, name: iconic.name, color: "#12AB9F", initial: "PX", icon: .reset)
            try require(!fileManager.fileExists(atPath: store.locations.customIcon(recolored).path) && recolored.iconInitial == "PX", "reset icon")
            try require(icns(recolored, store) != customIcns && icns(recolored, store) != defaultIcon, "reset icns")
            try verifySignature(store.locations.app(recolored))
            let custom2 = try store.update(recolored, name: recolored.name, color: recolored.color, initial: "", icon: .custom(png))
            print("Custom icon set, changed, reset; signature valid; data untouched")

            // Clone profile A into B: source untouched, copies independent.
            try ensureDirectory(store.locations.storage(custom2).appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb"))
            try Data("leveldb".utf8).write(to: store.locations.storage(custom2).appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb/000003.log"))
            let sourceBefore = snapshot(store.locations.storage(custom2))
            let copy = try store.create(name: "Personal Copy", color: profileColors[3], source: .profile(custom2))
            let copyData = store.locations.storage(copy)
            try require(snapshot(store.locations.storage(custom2)) == sourceBefore, "clone source intact")
            try require(try String(contentsOf: copyData.appendingPathComponent("Cookies"), encoding: .utf8) == "personal opaque", "clone has data")
            try require(fileManager.fileExists(atPath: copyData.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb/000003.log").path), "clone has nested data")
            try require(try String(contentsOf: copyData.appendingPathComponent(spaceMarker), encoding: .utf8) == copy.id, "clone owns its data")
            try require(!fileManager.fileExists(atPath: store.locations.customIcon(copy).path), "clone does not inherit icon")
            try Data("changed in copy".utf8).write(to: copyData.appendingPathComponent("Cookies"))
            try Data("new".utf8).write(to: copyData.appendingPathComponent("only-in-copy"))
            try require(snapshot(store.locations.storage(custom2)) == sourceBefore, "clone independent from source")
            try verifySignature(store.locations.app(copy))
            print("Cloned Personal into Personal Copy; source unchanged; copies independent")

            // Clone from Claude Desktop's own data folder (a stand-in here).
            if store.apps(using: .original).isEmpty {
                try ensureDirectory(fakeOriginal)
                try Data(#"{"mcpServers":{"demo":{"command":"true"}}}"#.utf8).write(to: fakeOriginal.appendingPathComponent("claude_desktop_config.json"))
                try Data("original opaque".utf8).write(to: fakeOriginal.appendingPathComponent("Cookies"))
                let originalBefore = snapshot(fakeOriginal)
                let fromOriginal = try store.create(name: "From Original", color: profileColors[4], source: .original)
                try require(snapshot(fakeOriginal) == originalBefore, "original intact")
                let config = try JSONSerialization.jsonObject(with: Data(contentsOf: store.locations.storage(fromOriginal).appendingPathComponent("claude_desktop_config.json"))) as! [String: Any]
                try require(config["mcpServers"] != nil && config["disableAutoUpdates"] as? Bool == true, "config kept and seeded")
                print("Created profile from Claude original data; original unchanged")
            } else { print("SKIPPED original-source test: Claude Desktop is running") }

            // Import into an existing profile: backup, identity kept, source untouched.
            let secondData = store.locations.storage(second)
            try Data("work only".utf8).write(to: secondData.appendingPathComponent("work-only.txt"))
            let secondIconic = try store.update(second, name: second.name, color: second.color, icon: .custom(png))
            let secondBefore = snapshot(secondData)
            do { _ = try store.importData(into: secondIconic, from: .profile(copy), fault: { throw Failure("injected") }); throw Failure("fault ignored") }
            catch let e as Failure { guard e.message.contains("restored") else { throw e } }
            try require(snapshot(secondData) == secondBefore, "rollback restores destination")
            try require(try fileManager.contentsOfDirectory(atPath: store.locations.data.appendingPathComponent("profiles").path).allSatisfy { !$0.hasPrefix(".") }, "no staging left")
            print("Import failure rolled back; destination unchanged")
            let copyBefore = snapshot(copyData)
            let importBackup = try store.importData(into: secondIconic, from: .profile(copy))
            try require(snapshot(copyData) == copyBefore, "import source intact")
            try require(try String(contentsOf: secondData.appendingPathComponent("Cookies"), encoding: .utf8) == "changed in copy", "imported data")
            try require(!fileManager.fileExists(atPath: secondData.appendingPathComponent("work-only.txt").path), "old data replaced")
            try require(try String(contentsOf: secondData.appendingPathComponent(spaceMarker), encoding: .utf8) == second.id, "identity kept")
            try require(fileManager.fileExists(atPath: store.locations.customIcon(secondIconic).path), "icon kept")
            try require(fileManager.fileExists(atPath: importBackup.appendingPathComponent("data/work-only.txt").path), "import backup")
            try require(try store.load().first { $0.id == second.id } == secondIconic, "registry identity kept")
            print("Imported Personal Copy into Work; backup kept; identity and icon kept")
            // Duplicate: new identity everywhere, same data/color/icon, no filesystem link between the two.
            let workNow = try store.load().first { $0.id == second.id }!
            let workData = store.locations.storage(workNow)
            let workBefore = snapshot(workData), workIcns = icns(workNow, store)
            let dup = try store.duplicate(workNow, name: "Work Copy")
            let dupData = store.locations.storage(dup)
            try require(dup.id != workNow.id && dup.bundleID != workNow.bundleID && dupData != workData && dup.createdAt > workNow.createdAt, "duplicate identity")
            try require(dup.color == workNow.color && dup.initial == workNow.initial, "duplicate appearance")
            try require(try Data(contentsOf: store.locations.customIcon(dup)) == Data(contentsOf: store.locations.customIcon(workNow)), "duplicate icon")
            let strip = { (d: [String: Data]) in d.filter { !["/" + spaceMarker, "/" + spaceLock].contains($0.key) } }
            try require(strip(snapshot(dupData)) == strip(workBefore), "duplicate data equal")
            try require(snapshot(workData) == workBefore, "duplicate source intact")
            let a = try fileManager.attributesOfItem(atPath: workData.appendingPathComponent("Cookies").path)
            let b = try fileManager.attributesOfItem(atPath: dupData.appendingPathComponent("Cookies").path)
            try require(a[.systemFileNumber] as? Int != b[.systemFileNumber] as? Int && b[.referenceCount] as? Int == 1, "no hardlink")
            try require((try? fileManager.destinationOfSymbolicLink(atPath: dupData.path)) == nil, "no symlink")
            try verifySignature(store.locations.app(dup))
            try Data("dup only".utf8).write(to: dupData.appendingPathComponent("Cookies"))
            let dup2 = try store.update(dup, name: dup.name, color: "#000000", icon: .reset)
            try require(snapshot(workData) == workBefore && icns(workNow, store) == workIcns, "duplicate changes isolated")
            _ = try store.delete(dup2)
            try require(snapshot(workData) == workBefore && ownedApp(store.locations.app(workNow), workNow), "source fine after deleting duplicate")
            print("Duplicated Work; independent data, identity and icon; deleting the copy left Work intact")

            // Failed duplicates leave nothing behind.
            let profileDirs = { Set(try fileManager.contentsOfDirectory(atPath: store.locations.data.appendingPathComponent("profiles").path)) }
            let appsBefore = Set(try fileManager.contentsOfDirectory(atPath: store.locations.apps.path)), dirsBefore = try profileDirs(), registryBefore = try store.load()
            let unreadable = workData.appendingPathComponent("unreadable.db")
            try Data("x".utf8).write(to: unreadable)
            try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            do { _ = try store.duplicate(workNow, name: "Broken Copy"); throw Failure("copy failure ignored") }
            catch let e as Failure { guard e.message != "copy failure ignored" else { throw e } }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
            try fileManager.removeItem(at: unreadable)
            do { _ = try store.duplicate(workNow, name: "Late Failure", fault: { throw Failure("injected") }); throw Failure("fault ignored") }
            catch let e as Failure { guard e.message == "injected" else { throw e } }
            try require(try profileDirs() == dirsBefore && Set(try fileManager.contentsOfDirectory(atPath: store.locations.apps.path)) == appsBefore
                        && (try store.load()) == registryBefore, "no partial profile after failure")
            try require(snapshot(workData) == workBefore, "source intact after failures")
            print("Copy failure and late failure left no partial profile")
            print("Integration passed. Generated apps remain at \(store.locations.apps.path)")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
