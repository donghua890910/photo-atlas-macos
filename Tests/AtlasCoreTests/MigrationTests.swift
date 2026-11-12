import XCTest
import CSQLite
@testable import AtlasCore

final class MigrationTests: XCTestCase {
    func testVersionFifteenPeopleJournalMigratesWithoutLosingItsSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("atlas.sqlite")
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        let operationID: String
        do {
            let store = try Store(url: url)
            try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
            try store.recordPersonCandidates(assetID: id, names: ["小明"])
            operationID = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["家庭"])).id
        }
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &old), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(old, "DROP TABLE automatic_writes; DROP TABLE privacy_decisions; DROP TABLE scan_control; ALTER TABLE people_operations DROP COLUMN source; PRAGMA user_version=15;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(old)
        let migrated = try Store(url: url)
        XCTAssertEqual(try migrated.latestPeopleOperation(assetID: id)?.id, operationID)
        XCTAssertNil(try migrated.latestLocationOperation(assetID: id))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("atlas-before-v15-") })
    }

    func testExistingVersionFourDataSurvivesQueueUpgrade() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("atlas.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE results(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,sensitive INTEGER,write_state TEXT,updated_at TEXT);
        INSERT INTO results VALUES('existing','已有描述','["标签"]',0,'pending',CURRENT_TIMESTAMP);
        CREATE TABLE legacy_records(source TEXT,asset_id TEXT,filename TEXT,ai_state TEXT,gps_state TEXT,PRIMARY KEY(source,asset_id));
        CREATE TABLE write_snapshots(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,created_at TEXT);
        CREATE TABLE write_receipts(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,added_keywords TEXT,status TEXT);
        PRAGMA user_version=4;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try Store(url: url)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("atlas-before-v4-") && $0.pathExtension == "sqlite" })
        var backupDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path, &backupDB, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(backupDB, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 4)
        sqlite3_finalize(statement)
        sqlite3_close(backupDB)
        XCTAssertEqual(try store.result(assetID: "existing")?.description, "已有描述")
        try store.enqueue(assetID: "new", kind: .ai, priority: 1)
        XCTAssertEqual(try store.outstanding(kind: .ai), 1)
    }
    func testUpgradeBackupIncludesUncheckpointedWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("atlas.sqlite")
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &old), SQLITE_OK)
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE results(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,sensitive INTEGER,write_state TEXT,updated_at TEXT);
        INSERT INTO results VALUES('wal','来自日志','["词"]',0,'pending',CURRENT_TIMESTAMP);
        CREATE TABLE legacy_records(source TEXT,asset_id TEXT,filename TEXT,ai_state TEXT,gps_state TEXT,PRIMARY KEY(source,asset_id));
        CREATE TABLE write_snapshots(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,created_at TEXT);
        CREATE TABLE write_receipts(asset_id TEXT PRIMARY KEY,description TEXT,keywords TEXT,added_keywords TEXT,status TEXT);
        PRAGMA user_version=4;
        """
        XCTAssertEqual(sqlite3_exec(old, sql, nil, nil, nil), SQLITE_OK)
        let store = try Store(url: url)
        XCTAssertEqual(try store.result(assetID: "wal")?.description, "来自日志")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("atlas-before-v4-") && $0.pathExtension == "sqlite" })
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT count(*) FROM results WHERE asset_id='wal'", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        sqlite3_finalize(stmt)
        sqlite3_close(copy)
        sqlite3_close(old)
    }

}
