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
        // Keep the lock across exec. The app runs at the same PID in the same bundle.
        _ = fcntl(lock, F_SETFD, 0)
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
        let executable = bundle.appendingPathComponent("Contents/MacOS/Claude").path
        guard fileManager.isExecutableFile(atPath: executable) else { throw Failure("Claude executable is missing. Rebuild this space.") }
        let args = [executable, "--user-data-dir=\(data.path)", "--disk-cache-dir=\(data.appendingPathComponent("Cache").path)"]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { for pointer in cArgs { free(pointer) }; close(lock) }
        // No auth URLs, cookies, console output or tokens are collected by Forkspaces.
        let null = Darwin.open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDOUT_FILENO); dup2(null, STDERR_FILENO); close(null) }
        cArgs.withUnsafeBufferPointer { _ = execv(executable, $0.baseAddress!) }
        throw Failure("macOS could not execute this space (errno \(errno)). Rebuild it in Forkspaces.")
    }
}
