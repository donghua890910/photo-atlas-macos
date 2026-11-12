import XCTest
import CSQLite
@testable import AtlasCore

final class LegacyImportTests: XCTestCase {
    func testImportPreservesSourceAndNeverMarksLegacySuccessVerified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("v8_progress.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE photos(uuid TEXT,filename TEXT,ai_state TEXT,gps_state TEXT); INSERT INTO photos VALUES('A','a.jpg','success','success'); INSERT INTO photos VALUES('B','b.jpg','sensitive','pending');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try Store(url: dir.appendingPathComponent("new.sqlite"))
        XCTAssertEqual(try store.importLegacy(from: source), 2)
        XCTAssertEqual(try store.importLegacy(from: source), 2)
        let records = try store.legacyRecords(assetID: "A")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].source, "v8_progress.sqlite3")
        XCTAssertEqual(records[0].aiState, "success")
        XCTAssertFalse(records[0].verified)
        XCTAssertNil(try store.result(assetID: "A"))
    }

    func testUnknownDatabaseIsRejectedWithoutImporting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("unknown.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        sqlite3_close(db)
        let store = try Store(url: dir.appendingPathComponent("new.sqlite"))
        XCTAssertThrowsError(try store.importLegacy(from: source))
        XCTAssertTrue(try store.legacyRecords(assetID: "A").isEmpty)
    }
    func testFailedReimportRollsBackPreviousRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("v8_progress.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE photos(uuid TEXT,filename TEXT,ai_state TEXT,gps_state TEXT); INSERT INTO photos VALUES('A','a.jpg','success','pending');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try Store(url: dir.appendingPathComponent("new.sqlite"))
        XCTAssertEqual(try store.importLegacy(from: source), 1)
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO photos VALUES(NULL,'bad.jpg','success','pending')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try store.importLegacy(from: source))
        XCTAssertEqual(try store.legacyRecords(assetID: "A").count, 1)
    }

}
