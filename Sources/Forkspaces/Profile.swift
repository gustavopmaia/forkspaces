import Foundation
import AppKit
import Darwin

struct Profile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var color: String
    var sourceVersion: String
    var createdAt: Date
    var validation: String = "needs interactive validation"
    /// Optional for profiles.json written by earlier versions; nil means the first letter of the name.
    var initial: String?
    var iconInitial: String { initial ?? String(name.prefix(1)).uppercased() }
    var bundleID: String { spaceBundlePrefix + id }
    var appName: String { "Claude \(name).app" }
}

let spaceBundlePrefix = "dev.gustavomaia.forkspaces.space."
/// Hidden files Forkspaces keeps in each data folder: ownership marker and launcher lock.
let spaceMarker = ".forkspaces-space", spaceLock = ".forkspaces.lock"

struct Locations: Sendable {
    let data: URL
    let apps: URL
    /// Claude Desktop's own data folder; only ever read as a copy source.
    var original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
    var originalCode = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static var standard: Locations {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Locations(data: home.appendingPathComponent("Library/Application Support/Forkspaces"),
                         apps: home.appendingPathComponent("Applications/Forkspaces"))
    }
    func storage(_ p: Profile) -> URL { data.appendingPathComponent("profiles/\(p.id)") }
    func app(_ p: Profile) -> URL { apps.appendingPathComponent(p.appName) }
    func customIcon(_ p: Profile) -> URL { storage(p).appendingPathComponent("icon/custom.png") }
}

enum DataSource: Sendable {
    case original
    case profile(Profile)
    /// The data folder inside a mounted export.
    case archive(URL)
    var name: String {
        switch self {
        case .original: return "Claude"
        case .profile(let p): return p.name
        case .archive: return "the export"
        }
    }
}

enum IconChange: Sendable { case keep, custom(Data), reset }

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let officialApp = URL(fileURLWithPath: "/Applications/Claude.app")
let fileManager = FileManager.default

func validateName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 48,
          !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\\"),
          trimmed != ".", trimmed != ".." else {
        throw Failure("Use a name of 1–48 characters without slashes, colons or control characters.")
    }
    return trimmed
}

func validateInitial(_ value: String) throws -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    guard trimmed.count <= 2, !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
        throw Failure("Use one or two characters for the icon initial.")
    }
    return trimmed
}

func validID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 90 && id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
}

func readPlist(_ url: URL) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
        throw Failure("Invalid property list: \(url.lastPathComponent)")
    }
    return result
}

func writePlist(_ value: [String: Any], _ url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
}

@discardableResult
func run(_ executable: String, _ args: [String], input: Data? = nil) throws -> Data {
    let task = Process(), pipe = Pipe(), stdin = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    task.standardOutput = pipe
    // Never pipe Claude or credential material into errors/logs.
    task.standardError = FileHandle.nullDevice
    if input != nil { task.standardInput = stdin }
    try task.run()
    if let input { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(task.terminationStatus)). No space data was deleted.")
    }
    return output
}

/// Takes an existing lock file without creating it: nil when absent, throws `busy` when another process holds it.
func holdLock(_ url: URL, busy: String) throws -> Int32? {
    let fd = Darwin.open(url.path, O_RDWR | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure(busy) }
    return fd
}

func releaseLock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

func rejectSymlink(_ url: URL) throws {
    var current = url.standardizedFileURL
    while current.path != "/" {
        if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw Failure("A managed path is a symbolic link: \(current.path). Choose a real directory.")
        }
        current.deleteLastPathComponent()
    }
}

/// Allocated bytes under a folder. Sizes only; file contents are never read. APFS clones still count in full.
func diskUsage(_ dir: URL) -> Int64 {
    var total: Int64 = 0
    for case let url as URL in fileManager.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) ?? .init() {
        total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}

func ownedApp(_ url: URL, _ profile: Profile) -> Bool {
    guard let info = try? readPlist(url.appendingPathComponent("Contents/Info.plist")) else { return false }
    return info["CFBundleIdentifier"] as? String == profile.bundleID && info["ForkspacesSpaceID"] as? String == profile.id
}

func runningApps(_ profile: Profile, at url: URL) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleID).filter {
        $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
    }
}

func stopProfile(_ profile: Profile, at url: URL) async throws {
    let apps = runningApps(profile, at: url)
    for app in apps {
        guard app.terminate() else { throw Failure("Could not ask \(profile.name) to quit. Close its window and try again.") }
    }
    for _ in 0..<100 {
        if apps.allSatisfy(\.isTerminated) { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw Failure("\(profile.name) is still closing. No force quit was issued; other spaces were not stopped.")
}

func openProfile(_ profile: Profile, at url: URL) async throws {
    guard ownedApp(url, profile) else { throw Failure("Space application is missing or changed. Use Rebuild from Claude.") }
    if let existing = runningApps(profile, at: url).first {
        existing.activate(options: [.activateAllWindows]); return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
}

struct LauncherConfiguration: Codable {
    let profileID: String
    let bundleID: String
    let name: String
    let dataDirectory: String
}
