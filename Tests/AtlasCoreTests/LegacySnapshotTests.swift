import XCTest
import CSQLite
@testable import AtlasCore

final class LegacySnapshotTests: XCTestCase {
    func testSnapshotIncludesCommittedWALAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite")
        let dest = dir.appendingPathComponent("snapshot.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE x(v TEXT); INSERT INTO x VALUES('committed');", nil, nil, nil), SQLITE_OK)
        try LegacySnapshot.copyDatabase(source: source, destination: dest)
        XCTAssertThrowsError(try LegacySnapshot.copyDatabase(source: source, destination: dest))
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dest.path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT count(*) FROM x", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        sqlite3_finalize(stmt)
        sqlite3_close(copy)
        sqlite3_close(db)
    }
}
