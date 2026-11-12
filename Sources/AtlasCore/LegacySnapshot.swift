import Foundation
import CSQLite
import Darwin

public enum LegacySnapshot {
    /// Uses SQLite's backup API so committed WAL entries are included without changing the source database.
    public static func copyDatabase(source: URL, destination: URL) throws {
        var input: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let input else {
            if let input { sqlite3_close(input) }
            throw StoreError.database("无法只读打开旧数据库")
        }
        defer { sqlite3_close(input) }
        sqlite3_busy_timeout(input, 5000)
        let fd = open(destination.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError.database("无法创建快照，目标可能已存在") }
        close(fd)
        do {
            var output: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let output else {
                if let output { sqlite3_close(output) }
                throw StoreError.database("无法打开快照")
            }
            sqlite3_busy_timeout(output, 5000)
            guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
                sqlite3_close(output)
                throw StoreError.database("无法初始化旧库备份")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                sqlite3_close(output)
                throw StoreError.database("旧库快照未完成")
            }
            var mode: OpaquePointer?
            let preparedMode = sqlite3_prepare_v2(output, "PRAGMA journal_mode=DELETE", -1, &mode, nil)
            let modeOK = preparedMode == SQLITE_OK && sqlite3_step(mode) == SQLITE_ROW && sqlite3_column_text(mode, 0).map { String(cString: $0) } == "delete"
            sqlite3_finalize(mode)
            guard modeOK else {
                sqlite3_close(output)
                throw StoreError.database("无法整理快照日志")
            }
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(output, "PRAGMA quick_check", -1, &statement, nil)
            let checked = prepared == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_text(statement, 0).map { String(cString: $0) } == "ok"
            sqlite3_finalize(statement)
            let closed = sqlite3_close(output)
            guard checked, closed == SQLITE_OK else { throw StoreError.database("快照完整性检查失败") }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
