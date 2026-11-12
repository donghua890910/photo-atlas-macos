import XCTest
import CSQLite
@testable import AtlasCore

final class PrivacyDecisionTests: XCTestCase {
    func testUpgradeRestoresAutomaticallyBlockedResultsAndKeepsManualProhibitions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            try store.cache(assetID: "auto", description: "业务统计表包含负责人", keywords: ["统计表"], sensitive: false)
            try store.cache(assetID: "manual", description: "文档", keywords: ["文件"], sensitive: true)
            try store.enqueueAIAssets(["auto", "manual"], priority: 10, automaticallyWrite: true)
            try store.markPendingSensitive(assetID: "manual")
            try store.setScanEnabled(true)
        }
        var fixture: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &fixture), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(fixture, "UPDATE results SET write_state='blocked' WHERE asset_id='auto'; PRAGMA user_version=19;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(fixture)

        let store = try Store(url: url)
        XCTAssertEqual(try store.result(assetID: "auto")?.writeState, .pending)
        XCTAssertEqual(try store.result(assetID: "auto")?.sensitive, true)
        XCTAssertEqual(try store.result(assetID: "manual")?.writeState, .blocked)
        XCTAssertTrue(try store.hasManualPrivacyDecision(assetID: "manual"))
        XCTAssertEqual(try store.nextAutomaticWrite(), "auto")
    }

    func testManualFlagCancelsUnstartedWriteButPreservesSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "photo", description: "照片", keywords: ["照片"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        try store.markPendingSensitive(assetID: "photo")
        XCTAssertTrue(try store.hasManualPrivacyDecision(assetID: "photo"))
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .blocked)
        XCTAssertEqual(try store.snapshot(assetID: "photo")?.keywords, ["原词"])
        XCTAssertFalse(try store.hasQueuedWrite(assetID: "photo"))
        XCTAssertNil(try store.claimNext(now: 100, leaseSeconds: 180, kind: .write))
        XCTAssertThrowsError(try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"]))
    }

    func testInFlightWriteCannotBeSilentlyCancelledOrHideUncertainty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "photo", description: "照片", keywords: ["照片"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .write))
        XCTAssertThrowsError(try store.markPendingSensitive(assetID: "photo"))
        XCTAssertFalse(try store.hasManualPrivacyDecision(assetID: "photo"))
        XCTAssertEqual(try store.taskState(id: task.id), "running")
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .writing)
    }

    func testManualFlagCancelsOnlyPreparedMetadataAndBlocksFutureNamesAndLocations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["照片"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["中国"]))
        _ = try store.preparePeopleWrite(assetID: id, description: "", keywords: [])
        try store.markPendingSensitive(assetID: id)
        XCTAssertNil(try store.latestPeopleOperation(assetID: id))
        XCTAssertThrowsError(try store.preparePeopleWrite(assetID: id, description: "", keywords: []))
        XCTAssertThrowsError(try store.prepareLocationWrite(assetID: id, description: "", keywords: []))
        XCTAssertEqual(try store.personCandidates(assetID: id), ["小明"])
    }
}
