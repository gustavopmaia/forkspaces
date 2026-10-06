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
        // APFS clone gives independent inodes with copy-on-write blocks. Never hardlink.
        do { try run("/bin/cp", ["-cR", source.path, destination.path]) }
        catch {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try run("/usr/bin/ditto", [source.path, destination.path])
        }
        let contents = destination.appendingPathComponent("Contents")
        var info = sourceInfo
        info["CFBundleIdentifier"] = profile.bundleID
        info["CFBundleName"] = "Claude \(profile.name)"
        info["CFBundleDisplayName"] = "Claude \(profile.name)"
        info["CFBundleExecutable"] = "ForkspacesLauncher"
        info["CFBundleIconFile"] = "Forkspaces.icns"
        info.removeValue(forKey: "CFBundleIconName")
        info.removeValue(forKey: "ElectronTeamID")
        info.removeValue(forKey: "CFBundleDocumentTypes")
        info.removeValue(forKey: "UTExportedTypeDeclarations")
        info.removeValue(forKey: "UTImportedTypeDeclarations")
        info["ForkspacesSpaceID"] = profile.id
        info["ForkspacesSourceVersion"] = profile.sourceVersion
        // Explicit routing can choose this bundle for browser fallback; no custom OAuth protocol.
        info["CFBundleURLTypes"] = [["CFBundleURLName": profile.bundleID,
                                    "CFBundleURLSchemes": ["claude", "msauth.com.anthropic.claudefordesktop"],
                                    "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]]
        try writePlist(info, contents.appendingPathComponent("Info.plist"))
        try fileManager.copyItem(at: resources.appendingPathComponent("ForkspacesLauncher"),
                                 to: contents.appendingPathComponent("MacOS/ForkspacesLauncher"))
        let config = LauncherConfiguration(profileID: profile.id, bundleID: profile.bundleID, name: profile.name, dataDirectory: data.path)
        try JSONEncoder().encode(config).write(to: contents.appendingPathComponent("Resources/Forkspaces.json"), options: .atomic)
        try makeProfileIcon(profile, data: data, at: contents.appendingPathComponent("Resources/Forkspaces.icns"))
        // Copies have a new local identity. No Anthropic provisioning or restricted Keychain groups.
        if let iterator = fileManager.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in iterator {
                if url.lastPathComponent == "embedded.provisionprofile" { try fileManager.removeItem(at: url) }

            }
        }
        // Electron resolves helper bundle paths from the native application name.
        let frameworks = contents.appendingPathComponent("Frameworks")
        for suffix in ["", " (GPU)", " (Plugin)", " (Renderer)"] {
            let oldName = "Claude Helper" + suffix
            let newName = "Claude \(profile.name) Helper" + suffix
            let oldHelper = frameworks.appendingPathComponent(oldName + ".app")
            let helper = frameworks.appendingPathComponent(newName + ".app")
            try fileManager.moveItem(at: oldHelper, to: helper)
            let helperContents = helper.appendingPathComponent("Contents")
            var helperInfo = try readPlist(helperContents.appendingPathComponent("Info.plist"))
            helperInfo["CFBundleIdentifier"] = profile.bundleID + ".helper" + (suffix.isEmpty ? "" : "." + suffix.filter { $0.isLetter }.lowercased())
            helperInfo["CFBundleExecutable"] = newName
            helperInfo["CFBundleName"] = newName
            helperInfo["CFBundleDisplayName"] = newName
            helperInfo.removeValue(forKey: "ElectronTeamID")
            try fileManager.moveItem(at: helperContents.appendingPathComponent("MacOS/" + oldName),
                                     to: helperContents.appendingPathComponent("MacOS/" + newName))
            try writePlist(helperInfo, helperContents.appendingPathComponent("Info.plist"))
        }
        // Only the generated clone is de-quarantined and re-signed. Never the source.
        try run("/usr/bin/xattr", ["-cr", destination.path])
        try sign(destination)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
    }

    func sign(_ app: URL) throws {
        var binaries: [URL] = [], bundles: [URL] = []
        if let iterator = fileManager.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) {
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true && ["app", "framework", "xpc"].contains(url.pathExtension) { bundles.append(url) }
                if values.isRegularFile == true, let handle = try? FileHandle(forReadingFrom: url) {
                    let header = try? handle.read(upToCount: 4)
                    try? handle.close()
                    if let header, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xce,0xfa,0xed,0xfe]), Data([0xca,0xfe,0xba,0xbe]), Data([0xca,0xfe,0xba,0xbf])].contains(header) {
                        binaries.append(url)
                    }
                }
            }
        }
        for item in binaries + bundles.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) + [app] {
            try codesign(item)
        }
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
