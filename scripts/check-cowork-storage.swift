// swiftc -module-cache-path .build/module-cache Sources/Forkspaces/Profile.swift \
//   Sources/Forkspaces/CoworkStorage.swift scripts/check-cowork-storage.swift -o build/check-cowork-storage
// build/check-cowork-storage
import Foundation
import Darwin

@main
struct CheckCoworkStorage {
    static func main() throws {
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("build/cowork-check-\(UUID().uuidString)")
        try ensureDirectory(root)
        defer { try? fileManager.removeItem(at: root) }
        let a = root.appendingPathComponent("a-12345678"), b = root.appendingPathComponent("b-12345678")
        let suffix = "vm_bundles/claudevm.bundle/rootfs.img"
        for p in [a, b] {
            try ensureDirectory(p.appendingPathComponent("vm_bundles/claudevm.bundle"))
            try Data(p.lastPathComponent.utf8).write(to: p.appendingPathComponent(spaceMarker))
            try Data().write(to: p.appendingPathComponent(spaceLock))
        }
        let source = a.appendingPathComponent(suffix), target = b.appendingPathComponent(suffix)
        var base = Data(repeating: 0x42, count: 6 * 1_048_576 + 13)
        var expected = base
        for offset in [0, 2 * 1_048_576 + 100, expected.count - 1] { expected[offset] = 0x71 }
        try base.write(to: source); try expected.write(to: target)
        let process = Process(), ready = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('1',flush=True); sys.stdin.read()", a.appendingPathComponent(spaceLock).path]
        process.standardOutput = ready; process.standardInput = input
        try process.run()
        _ = try ready.fileHandleForReading.read(upToCount: 2)
        precondition(tryValue { try optimizeCoworkStorage(b) } == 0, "Running source must be skipped")
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        let shared = try optimizeCoworkStorage(b)
        precondition(shared == 4 * 1_048_576, "Only identical blocks should be shared")
        precondition(tryValue { try Data(contentsOf: target) } == expected, "Preserve every target byte")
        precondition(tryValue { try Data(contentsOf: source) } == base, "Source untouched")
        precondition(tryValue { try optimizeCoworkStorage(b) } == 0, "Skip already optimized inode")
        let sa = try fileManager.attributesOfItem(atPath: source.path)
        let ta = try fileManager.attributesOfItem(atPath: target.path)
        precondition(sa[.systemFileNumber] as? UInt64 != ta[.systemFileNumber] as? UInt64)
        precondition(ta[.referenceCount] as? Int == 1, "Never hardlink images")
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: 1_048_576); try handle.write(contentsOf: Data([0x99])); try handle.close()
        precondition(tryValue { try Data(contentsOf: target) } == expected, "Source writes stay isolated")
        let targetHandle = try FileHandle(forWritingTo: target)
        try targetHandle.seek(toOffset: 3 * 1_048_576); try targetHandle.write(contentsOf: Data([0x98])); try targetHandle.close()
        base[1_048_576] = 0x99
        precondition(tryValue { try Data(contentsOf: source) } == base, "Target writes stay isolated")
        let small = root.appendingPathComponent("small")
        try Data([1]).write(to: small)
        precondition(tryValue { try cloneCoworkImage(target, from: small) } == 0, "Different sizes skipped")
        let link = root.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try cloneCoworkImage(target, from: link); fatalError("Symlink accepted") }
        catch { }
        let remaining = try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".forkspaces-vm-") })
        print("PASS: shared blocks, exact bytes, isolated writes, running-source lock, inode marker, size and symlink guards")
    }
    static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }
}
