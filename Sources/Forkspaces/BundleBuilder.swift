import Foundation
import AppKit

struct BundleBuilder: Sendable {
    let resources: URL
    let source: URL

    func build(_ profile: Profile, data: URL, destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !destination.path.hasPrefix(source.path + "/") else { throw Failure("Invalid clone destination.") }
        guard !fileManager.fileExists(atPath: destination.path) else { throw Failure("The app destination already exists.") }
        let sourceInfo = try readPlist(source.appendingPathComponent("Contents/Info.plist"))
        guard sourceInfo["CFBundleIdentifier"] as? String == "com.anthropic.claudefordesktop",
              sourceInfo["CFBundleExecutable"] as? String == "Claude" else { throw Failure("Select the official Claude Desktop bundle.") }
        // Keep Claude's signed bundle intact. Its device key lives in an Anthropic
        // Keychain access group: re-signing Electron removes access and disconnects Cowork.
        let contents = destination.appendingPathComponent("Contents")
        try ensureDirectory(contents.appendingPathComponent("MacOS"))
        try ensureDirectory(contents.appendingPathComponent("Resources"))
        try ensureDirectory(contents.appendingPathComponent("Helpers"))
        let runtime = claudeRuntime(in: destination)
        do { try run("/bin/cp", ["-cR", source.path, runtime.path]) }
        catch {
            if fileManager.fileExists(atPath: runtime.path) { try fileManager.removeItem(at: runtime) }
            try run("/usr/bin/ditto", [source.path, runtime.path])
        }
        try verifyClaudeRuntime(runtime)
        let info: [String: Any] = [
            "CFBundleIdentifier": profile.bundleID,
            "CFBundleName": "Claude \(profile.name)",
            "CFBundleDisplayName": "Claude \(profile.name)",
            "CFBundleExecutable": "ForkspacesLauncher",
            "CFBundleIconFile": "Forkspaces.icns",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": profile.sourceVersion,
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true,
            "NSPrincipalClass": "NSApplication",
            "ForkspacesSpaceID": profile.id,
            "ForkspacesSourceVersion": profile.sourceVersion,
            "CFBundleURLTypes": [["CFBundleURLName": profile.bundleID,
                                  "CFBundleURLSchemes": ["claude", "msauth.com.anthropic.claudefordesktop"],
                                  "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]]
        ]
        try writePlist(info, contents.appendingPathComponent("Info.plist"))
        try fileManager.copyItem(at: resources.appendingPathComponent("ForkspacesLauncher"),
                                 to: contents.appendingPathComponent("MacOS/ForkspacesLauncher"))
        let config = LauncherConfiguration(profileID: profile.id, bundleID: profile.bundleID, name: profile.name, dataDirectory: data.path)
        try JSONEncoder().encode(config).write(to: contents.appendingPathComponent("Resources/Forkspaces.json"), options: .atomic)
        try makeProfileIcon(profile, data: data, at: contents.appendingPathComponent("Resources/Forkspaces.icns"))
        // Only the wrapper is signed by Forkspaces. Never recursively re-sign Claude.
        try codesign(destination)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
    }

    /// Signs one item only; nested code keeps its existing signature.
    func codesign(_ item: URL) throws {
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
                                     "--entitlements", resources.appendingPathComponent("Space.entitlements").path, item.path])
    }
}

/// The custom image lives with the profile data, so the launcher never depends on the user's original file.
func makeProfileIcon(_ p: Profile, data: URL, at url: URL) throws {
    try makeIcon(initial: p.iconInitial, color: p.color, image: NSImage(contentsOf: data.appendingPathComponent("icon/custom.png")), at: url)
}

/// Reject unsigned/tampered runtimes, including accidental recursive re-signing.
func verifyClaudeRuntime(_ app: URL) throws {
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict",
        "-R=anchor apple generic and identifier \"com.anthropic.claudefordesktop\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"", app.path])
}
