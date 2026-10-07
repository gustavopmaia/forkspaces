import Foundation
import AppKit
import Darwin

@main
struct Launcher {
    static func main() {
        do { try launch() }
        catch {
            let alert = NSAlert()
            alert.messageText = "This Claude space could not open"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            exit(1)
        }
    }

    static func launch() throws {
        let bundle = Bundle.main.bundleURL
        let configURL = bundle.appendingPathComponent("Contents/Resources/Forkspaces.json")
        let config = try JSONDecoder().decode(LauncherConfiguration.self, from: Data(contentsOf: configURL))
        guard validID(config.profileID), config.bundleID == spaceBundlePrefix + config.profileID,
              Bundle.main.bundleIdentifier == config.bundleID else { throw Failure("Invalid space application identity. Rebuild it in Forkspaces.") }
        let data = URL(fileURLWithPath: config.dataDirectory)
        guard data.path == config.dataDirectory, data.lastPathComponent == config.profileID else { throw Failure("Invalid space data path.") }
        try rejectSymlink(data)
        guard try String(contentsOf: data.appendingPathComponent(spaceMarker), encoding: .utf8) == config.profileID else { throw Failure("Space data is missing or belongs to another space.") }
        let lock = Darwin.open(data.appendingPathComponent(spaceLock).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure("Could not lock space storage.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: config.bundleID) where app.processIdentifier != getpid() && app.bundleURL == bundle {
                app.activate(options: [.activateAllWindows])
            }
            return
        }
        // Keep the lock in this process, but never pass it to Electron's helpers.
        _ = fcntl(lock, F_SETFD, FD_CLOEXEC)
        defer { close(lock) }
        let code = data.appendingPathComponent("ClaudeCode")
        let temporary = data.appendingPathComponent("tmp")
        try ensureDirectory(code); try ensureDirectory(temporary)
        unsetenv("CLAUDE_USER_DATA_DIR")
        unsetenv("ELECTRON_RUN_AS_NODE")
        unsetenv("NODE_OPTIONS")
        setenv("CLAUDE_CONFIG_DIR", code.path, 1)
        setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", code.path, 1)
        setenv("TMPDIR", temporary.path + "/", 1)
        // The local macOS preference domain is unique. HOME is intentionally unchanged.
        CFPreferencesSetAppValue("disableAutoUpdates" as CFString, kCFBooleanTrue, config.bundleID as CFString)
        CFPreferencesSetAppValue("disableDeepLinkRegistration" as CFString, kCFBooleanTrue, config.bundleID as CFString)
        CFPreferencesAppSynchronize(config.bundleID as CFString)
        // execv invalidates LaunchServices' process identity (NSRunningApplication PID -1),
        // preventing Rectangle and other accessibility clients from finding our windows.
        // Use the same entry point as Electron's native macOS executable, in this process.
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Electron Framework")
        guard let library = dlopen(framework.path, RTLD_NOW | RTLD_GLOBAL),
              let entry = dlsym(library, "ElectronMain") else {
            throw Failure("Could not load Claude's Electron framework. Rebuild this space.")
        }
        typealias ElectronMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let electronMain = unsafeBitCast(entry, to: ElectronMain.self)
        let executable = Bundle.main.executableURL!.path
        let args = [executable, "--user-data-dir=\(data.path)", "--disk-cache-dir=\(data.appendingPathComponent("Cache").path)"]
        var cArgs = args.map { strdup($0) } + [nil]
        defer { for pointer in cArgs { free(pointer) } }
        // No auth URLs, cookies, console output or tokens are collected by Forkspaces.
        let null = Darwin.open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); close(null) }
        let status = cArgs.withUnsafeMutableBufferPointer { electronMain(Int32(args.count), $0.baseAddress!) }
        exit(status)
    }
}
