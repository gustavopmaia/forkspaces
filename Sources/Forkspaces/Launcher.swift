import Foundation
import AppKit
import Darwin

@main
struct Launcher {
    static func main() {
        let application = NSApplication.shared
        let delegate = SpaceLauncher()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class SpaceLauncher: NSObject, NSApplicationDelegate {
    private var lock: Int32 = -1
    private var child: NSRunningApplication?
    private var pendingURLs: [URL] = []
    private var timer: Timer?
    private let bundle = Bundle.main.bundleURL

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() }
        catch { fail(error) }
    }

    private func fail(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "This Claude space could not open"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    private func launch() throws {
        let configURL = bundle.appendingPathComponent("Contents/Resources/Forkspaces.json")
        let config = try JSONDecoder().decode(LauncherConfiguration.self, from: Data(contentsOf: configURL))
        guard validID(config.profileID), config.bundleID == spaceBundlePrefix + config.profileID,
              Bundle.main.bundleIdentifier == config.bundleID else { throw Failure("Invalid space application identity. Rebuild it in Forkspaces.") }
        let data = URL(fileURLWithPath: config.dataDirectory)
        guard data.path == config.dataDirectory, data.lastPathComponent == config.profileID else { throw Failure("Invalid space data path.") }
        try rejectSymlink(data)
        guard try String(contentsOf: data.appendingPathComponent(spaceMarker), encoding: .utf8) == config.profileID else { throw Failure("Space data is missing or belongs to another space.") }
        lock = Darwin.open(data.appendingPathComponent(spaceLock).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure("Could not lock space storage.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
                .first { $0.bundleURL?.standardizedFileURL == claudeRuntime(in: bundle).standardizedFileURL }?
                .activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
            return
        }
        _ = fcntl(lock, F_SETFD, FD_CLOEXEC)
        _ = try? optimizeCoworkStorage(data)
        let code = data.appendingPathComponent("ClaudeCode")
        let temporary = data.appendingPathComponent("tmp")
        try ensureDirectory(code); try ensureDirectory(temporary)
        let runtime = claudeRuntime(in: bundle)
        guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("Contents/MacOS/Claude").path) else {
            throw Failure("Claude's signed runtime is missing. Rebuild this space.")
        }
        let options = NSWorkspace.OpenConfiguration()
        options.createsNewApplicationInstance = true
        options.arguments = ["--user-data-dir=\(data.path)", "--disk-cache-dir=\(data.appendingPathComponent("Cache").path)"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_USER_DATA_DIR", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS"] { environment.removeValue(forKey: key) }
        environment["CLAUDE_CONFIG_DIR"] = code.path
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = code.path
        environment["TMPDIR"] = temporary.path + "/"
        options.environment = environment
        // LaunchServices must launch the signed executable, in its own process:
        // dlopen loses its Keychain entitlements; execv loses its window identity.
        NSWorkspace.shared.openApplication(at: runtime, configuration: options) { app, error in
            DispatchQueue.main.async {
                guard let app, app.bundleURL?.standardizedFileURL == runtime.standardizedFileURL else {
                    self.fail(error ?? Failure("macOS did not open this space's Claude runtime.")); return
                }
                self.child = app
                self.forwardURLs()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    if app.isTerminated { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        child?.activate(options: [.activateAllWindows])
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter { ["claude", "msauth.com.anthropic.claudefordesktop"].contains($0.scheme ?? "") })
        forwardURLs()
    }

    private func forwardURLs() {
        guard child != nil, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        let options = NSWorkspace.OpenConfiguration()
        options.allowsRunningApplicationSubstitution = false
        // Address this bundle path explicitly, never the system's default Claude.
        NSWorkspace.shared.open(urls, withApplicationAt: claudeRuntime(in: bundle), configuration: options) { _, error in
            if error != nil { DispatchQueue.main.async { self.fail(Failure("Could not forward browser login to this space. Try signing in again.")) } }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let child, !child.isTerminated else { return .terminateNow }
        child.terminate()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if lock >= 0 { close(lock) }
    }
}
