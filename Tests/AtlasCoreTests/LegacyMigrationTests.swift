import XCTest
import CSQLite
@testable import AtlasCore

final class LegacyMigrationTests: XCTestCase {
    func testMigrationBacksUpAndImportsOnceWithoutMarkingVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("old")
        let support = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDB = source.appendingPathComponent("v8_progress.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(oldDB.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE photos(uuid TEXT,filename TEXT,ai_state TEXT,gps_state TEXT); INSERT INTO photos VALUES('old-id','a.jpg','success','pending');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try "{\"uuid\":\"old-id\",\"description\":\"说明\",\"keywords\":[\"词\"],\"sensitive\":false}\n".write(to: source.appendingPathComponent("v8_ai_results.jsonl"), atomically: true, encoding: .utf8)
        let result = try LegacyMigration.run(source: source, support: support)
        XCTAssertEqual(result, .imported(files: 2, records: 2))
        XCTAssertEqual(try LegacyMigration.run(source: source, support: support), .alreadyImported)
        let store = try Store(url: support.appendingPathComponent("atlas.sqlite"))
        XCTAssertEqual(try store.legacyRecords(assetID: "old-id").count, 1)
        XCTAssertEqual(try store.legacyResultCount(assetID: "old-id"), 1)
        XCTAssertNil(try store.result(assetID: "old-id"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDB.path))
    }

    func testInvalidHistoryDoesNotMarkMigrationComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("old"), support = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDB = source.appendingPathComponent("v8_progress.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(oldDB.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE photos(uuid TEXT,filename TEXT,ai_state TEXT,gps_state TEXT); INSERT INTO photos VALUES('partial','a.jpg','success','pending');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try "invalid\n".write(to: source.appendingPathComponent("v8_ai_results.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LegacyMigration.run(source: source, support: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("legacy-migration.json").path))
        let store = try Store(url: support.appendingPathComponent("atlas.sqlite"))
        XCTAssertTrue(try store.legacyRecords(assetID: "partial").isEmpty)
    }
}
