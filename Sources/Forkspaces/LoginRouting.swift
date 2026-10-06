import AppKit
import CoreServices

struct LoginRouting {
    let root: URL
    private let schemes = ["claude", "msauth.com.anthropic.claudefordesktop"]
    private var backup: URL { root.appendingPathComponent("login-routing.json") }
    var isActive: Bool { fileManager.fileExists(atPath: backup.path) }

    func select(_ p: Profile, app: URL) throws {
        guard ownedApp(app, p) else { throw Failure("Rebuild this space before routing login.") }
        try ensureDirectory(root)
        if !isActive {
            var handlers: [String: String] = [:]
            for scheme in schemes {
                let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: scheme + "://")!)
                handlers[scheme] = current.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "com.anthropic.claudefordesktop"
            }
            try JSONEncoder().encode(handlers).write(to: backup, options: .atomic)
        }
        for scheme in schemes {
            guard LSSetDefaultHandlerForURLScheme(scheme as CFString, p.bundleID as CFString) == noErr else {
                try? restore()
                throw Failure("macOS could not route browser login. Use Claude’s native login window or try again in your desktop session.")
            }
        }
    }

    func restore() throws {
        guard isActive else { return }
        let handlers = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: backup))
        for scheme in schemes {
            guard let target = handlers[scheme], LSSetDefaultHandlerForURLScheme(scheme as CFString, target as CFString) == noErr else { throw Failure("Could not restore the previous login handler. Try Restore browser routing again.") }
        }
        try fileManager.removeItem(at: backup)
    }
}
