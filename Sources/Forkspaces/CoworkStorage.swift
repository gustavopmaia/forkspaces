import Foundation
import CryptoKit
import Darwin

/// Rebuild an opaque image as an APFS clone plus its differing blocks. The published
/// file must remain byte-for-byte identical to the target; VM state is never shared.
@discardableResult
func cloneCoworkImage(_ target: URL, from source: URL) throws -> Int64 {
    try rejectSymlink(target); try rejectSymlink(source)
    let before = try fileManager.attributesOfItem(atPath: target.path)
    let reference = try fileManager.attributesOfItem(atPath: source.path)
    guard before[.type] as? FileAttributeType == .typeRegular,
          reference[.type] as? FileAttributeType == .typeRegular,
          let size = before[.size] as? Int64, size > 0,
          reference[.size] as? Int64 == size else { return 0 }
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".forkspaces-vm-\(UUID().uuidString)")
    // No ordinary-copy fallback: this operation only makes sense with shared APFS blocks.
    guard clonefile(source.path, temporary.path, 0) == 0 else {
        throw Failure("Cowork storage optimization requires APFS images on the same volume.")
    }
    defer { try? fileManager.removeItem(at: temporary) }
    let original = try FileHandle(forReadingFrom: target)
    defer { try? original.close() }
    let clone = try FileHandle(forUpdating: temporary)
    defer { try? clone.close() }
    var offset: UInt64 = 0, shared: Int64 = 0, expected = SHA256()
    // ponytail: 1 MiB comparisons bound memory; smaller blocks can improve sharing if needed.
    while offset < size {
        let count = Int(min(1_048_576, UInt64(size) - offset))
        guard let bytes = try original.read(upToCount: count), bytes.count == count,
              let base = try clone.read(upToCount: count), base.count == count else {
            throw Failure("A Cowork image changed while optimizing. The original was kept.")
        }
        expected.update(data: bytes)
        if bytes == base { shared += Int64(count) }
        else { try clone.seek(toOffset: offset); try clone.write(contentsOf: bytes) }
        offset += UInt64(count)
    }
    guard shared > 0 else { return 0 }
    try clone.synchronize()
    try clone.seek(toOffset: 0)
    var actual = SHA256()
    while let bytes = try clone.read(upToCount: 1_048_576), !bytes.isEmpty { actual.update(data: bytes) }
    let after = try fileManager.attributesOfItem(atPath: target.path)
    guard expected.finalize() == actual.finalize(),
          before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64,
          before[.size] as? Int64 == after[.size] as? Int64,
          before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
        throw Failure("Cowork image verification failed. The original was kept.")
    }
    guard copyfile(target.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
        throw Failure("Could not preserve Cowork image metadata. The original was kept.")
    }
    guard rename(temporary.path, target.path) == 0 else { throw Failure("Could not install the optimized image. The original was kept.") }
    return shared
}

/// Caller holds the target's launcher lock. Only stopped sibling spaces are used.
/// An inode marker avoids scanning 10 GB on every launch; Claude image replacement
/// (e.g. an update) naturally invalidates it. No VM identities or session disks copied.
func optimizeCoworkStorage(_ data: URL, force: Bool = false) throws -> Int64 {
    let bundle = data.appendingPathComponent("vm_bundles/claudevm.bundle")
    guard fileManager.fileExists(atPath: bundle.path) else { return 0 }
    try rejectSymlink(bundle)
    let marker = bundle.appendingPathComponent(".forkspaces-shared-images.json")
    try rejectSymlink(marker)
    var completed = (try? JSONDecoder().decode([String: UInt64].self, from: Data(contentsOf: marker))) ?? [:]
    let peers = try fileManager.contentsOfDirectory(at: data.deletingLastPathComponent(), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    var shared: Int64 = 0
    for name in ["rootfs.img", "rootfs.img.zst"] {
        let target = bundle.appendingPathComponent(name)
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path),
              let inode = attributes[.systemFileNumber] as? UInt64,
              force || completed[name] != inode else { continue }
        for peer in peers where peer.standardizedFileURL.path != data.standardizedFileURL.path {
            guard validID(peer.lastPathComponent), (try? rejectSymlink(peer)) != nil,
                  (try? String(contentsOf: peer.appendingPathComponent(spaceMarker), encoding: .utf8)) == peer.lastPathComponent,
                  let lock = try? holdLock(peer.appendingPathComponent(spaceLock), busy: "Space running") else { continue }
            defer { releaseLock(lock) }
            let source = peer.appendingPathComponent("vm_bundles/claudevm.bundle/" + name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let bytes = try cloneCoworkImage(target, from: source)
            if bytes > 0 {
                shared += bytes
                completed[name] = try fileManager.attributesOfItem(atPath: target.path)[.systemFileNumber] as? UInt64
                break
            }
        }
    }
    if !completed.isEmpty { try JSONEncoder().encode(completed).write(to: marker, options: .atomic) }
    return shared
}
