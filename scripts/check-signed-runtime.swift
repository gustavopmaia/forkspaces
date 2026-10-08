// Build with Profile.swift, Icon.swift, CoworkStorage.swift, BundleBuilder.swift and ProfileStore.swift.
// Run with the directory produced by ForkspacesTool integration. Uses only those disposable spaces.
import AppKit

@main
struct SignedRuntimeCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure("FAIL: \(message)") }
    }

    static func child(_ p: Profile, _ store: ProfileStore) -> NSRunningApplication? {
        runningApps(p, at: store.locations.app(p)).first {
            $0.bundleURL?.standardizedFileURL == claudeRuntime(in: store.locations.app(p)).standardizedFileURL && $0.processIdentifier > 0
        }
    }

    static func waitForChild(_ p: Profile, _ store: ProfileStore) async throws -> NSRunningApplication {
        for _ in 0..<200 {
            if let app = child(p, store) { return app }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure("FAIL: signed runtime did not launch")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure("Pass a disposable integration directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let resources = URL(fileURLWithPath: "build/Forkspaces.app/Contents/Resources").standardizedFileURL
        let store = ProfileStore(locations: Locations(data: root.appendingPathComponent("Data"), apps: root.appendingPathComponent("Applications")),
                                 builder: BundleBuilder(resources: resources, source: officialApp))
        let profiles = try store.load()
        guard let first = profiles.first(where: { $0.name == "Personal" }), let second = profiles.first(where: { $0.name == "Work" }) else {
            throw Failure("Run ForkspacesTool integration in this directory first")
        }
        let originalPIDs = store.apps(using: .original).map(\.processIdentifier)
        do {
            try await openProfile(first, at: store.locations.app(first))
            try await openProfile(second, at: store.locations.app(second))
            let a = try await waitForChild(first, store), b = try await waitForChild(second, store)
            try require(a.processIdentifier != b.processIdentifier, "spaces must have separate real processes")
            try verifyClaudeRuntime(claudeRuntime(in: store.locations.app(first)))
            try verifyClaudeRuntime(claudeRuntime(in: store.locations.app(second)))
            try await openProfile(first, at: store.locations.app(first))
            try require(child(first, store)?.processIdentifier == a.processIdentifier, "reopen must activate the same runtime")
            do { try store.withStoppedProfile(first) {}; throw Failure("FAIL: a running space was editable") }
            catch let e as Failure { try require(!e.message.hasPrefix("FAIL:"), e.message) }
            try require(store.apps(using: .original).map(\.processIdentifier) == originalPIDs, "inner runtimes must not count as original Claude")
            for _ in 0..<200 {
                if [first, second].allSatisfy({ fileManager.fileExists(atPath: store.locations.storage($0).appendingPathComponent("ant-did").path) }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for p in [first, second] {
                try require(fileManager.fileExists(atPath: store.locations.storage(p).appendingPathComponent("ant-did").path), "runtime writes into its own data directory")
            }
            try await stopProfile(first, at: store.locations.app(first))
            try require(runningApps(first, at: store.locations.app(first)).isEmpty, "stop must close wrapper and runtime")
            try require(child(second, store)?.processIdentifier == b.processIdentifier && !b.isTerminated, "stopping one space must leave the other running")
            try store.withStoppedProfile(first) {}
            try await stopProfile(second, at: store.locations.app(second))
            print("PASS: signed runtimes, two independent processes/data folders, reopen, locks, targeted stop, original untouched")
        } catch {
            try? await stopProfile(first, at: store.locations.app(first))
            try? await stopProfile(second, at: store.locations.app(second))
            throw error
        }
    }
}
