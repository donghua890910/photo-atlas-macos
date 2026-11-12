import Foundation
import Darwin

public enum LegacyMigrationResult: Equatable, Sendable {
    case noLegacy, alreadyImported, imported(files: Int, records: Int)
}

public enum LegacyMigration {
    private static let databases = ["photo_progress.sqlite3", "v4_progress.sqlite3", "v6_progress.sqlite3", "v8_progress.sqlite3"]
    private static let results = ["ai_results.jsonl", "v4_ai_results.jsonl", "v5_ai_results.jsonl", "v6_ai_results.jsonl", "v8_ai_results.jsonl"]

    /// Snapshots first, then imports unverified records. Originals are never changed.
    public static func run(source: URL, support: URL) throws -> LegacyMigrationResult {
        let fm = FileManager.default
        guard source.standardizedFileURL.resolvingSymlinksInPath() != support.standardizedFileURL.resolvingSymlinksInPath() else { throw StoreError.invalidInput }
        let files = (databases + results).filter { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        guard !files.isEmpty else { return .noLegacy }
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = support.appendingPathComponent("legacy-migration.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw StoreError.database("无法创建迁移锁") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.database("旧数据迁移正在进行") }
        let marker = support.appendingPathComponent("legacy-migration.json")
        if let data = try? Data(contentsOf: marker),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (value["version"] as? Int) == 1, let name = value["backup"] as? String,
           let recordedSource = value["source"] as? String,
           !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
           fm.fileExists(atPath: support.appendingPathComponent(name).path) {
            guard recordedSource == source.standardizedFileURL.resolvingSymlinksInPath().path else { throw StoreError.invalidInput }
            return .alreadyImported
        }
        let backupName = "LegacySnapshot-" + UUID().uuidString
        let backup = support.appendingPathComponent(backupName, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in files {
            let original = source.appendingPathComponent(name), copy = backup.appendingPathComponent(name)
            if databases.contains(name) { try LegacySnapshot.copyDatabase(source: original, destination: copy) }
            else { try copyStableFile(source: original, destination: copy) }
        }
        let store = try Store(url: support.appendingPathComponent("atlas.sqlite"))
        let count = try store.importLegacyBundle(files.map { backup.appendingPathComponent($0) })
        let info: [String: Any] = ["version": 1, "backup": backupName, "source": source.standardizedFileURL.resolvingSymlinksInPath().path, "files": files.count, "records": count]
        let encoded = try JSONSerialization.data(withJSONObject: info)
        try encoded.write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        return .imported(files: files.count, records: count)
    }

    private static func copyStableFile(source: URL, destination: URL) throws {
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = before.fileSize, size <= 50_000_000 else { throw StoreError.invalidInput }
        let data = try Data(contentsOf: source)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard data.count == size, before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw StoreError.database("旧记录正在变化，请稍后重试")
        }
        let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw StoreError.database("无法创建旧记录快照") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
    }
}
