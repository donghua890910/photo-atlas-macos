import XCTest
@testable import AtlasCore

final class StoreTests: XCTestCase {
    func testCachedResultSurvivesReopeningAndWaitsForWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            try store.cache(assetID: "asset-1", description: "海边的日落", keywords: ["海边", "夕阳"], sensitive: false, category: "风景")
        }
        let reopened = try Store(url: url)
        let item = try XCTUnwrap(reopened.result(assetID: "asset-1"))
        XCTAssertEqual(item.description, "海边的日落")
        XCTAssertEqual(item.keywords, ["海边", "夕阳"])
        XCTAssertEqual(item.category, "风景")
        XCTAssertEqual(item.writeState, .pending)
    }

    func testInterruptedWriteRequiresVerificationAfterRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            try store.cache(assetID: "asset-2", description: "照片", keywords: ["照片"], sensitive: false)
            try store.saveSnapshot(assetID: "asset-2", description: "原说明", keywords: ["已有"])
            try store.beginWrite(assetID: "asset-2")
        }
        let reopened = try Store(url: url)
        try reopened.recoverInterruptedWrites()
        XCTAssertEqual(try reopened.result(assetID: "asset-2")?.writeState, .needsVerification)
    }

    func testSensitiveResultCanEnterWriteQueue() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "asset-3", description: "敏感文件", keywords: ["文件"], sensitive: true)
        try store.approveWrite(assetID: "asset-3", description: "", keywords: [])
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .write))
        try store.confirmAndFinishWrite(task: task, now: 101, description: "敏感文件", keywords: ["文件"])
        XCTAssertEqual(try store.result(assetID: "asset-3")?.writeState, .verified)
        XCTAssertEqual(try store.result(assetID: "asset-3")?.sensitive, true)
    }
    func testExistingCachedResultCannotBeSilentlyOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "asset-4", description: "原结果", keywords: ["原标签"], sensitive: false)
        XCTAssertThrowsError(try store.cache(assetID: "asset-4", description: "新结果", keywords: ["新标签"], sensitive: false))
        XCTAssertEqual(try store.result(assetID: "asset-4")?.description, "原结果")
    }

    func testOnlyPendingItemsCanStartWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        XCTAssertThrowsError(try store.beginWrite(assetID: "missing"))
        try store.cache(assetID: "asset-5", description: "照片", keywords: ["照片"], sensitive: false)
        XCTAssertThrowsError(try store.beginWrite(assetID: "asset-5"))
        try store.saveSnapshot(assetID: "asset-5", description: "", keywords: ["原标签"])
        try store.beginWrite(assetID: "asset-5")
        XCTAssertThrowsError(try store.beginWrite(assetID: "asset-5"))
    }

    func testSnapshotPersistsAndCannotBeOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            try store.cache(assetID: "asset-6", description: "AI说明", keywords: ["新"], sensitive: false)
            try store.saveSnapshot(assetID: "asset-6", description: "原说明", keywords: ["原标签"])
            XCTAssertThrowsError(try store.saveSnapshot(assetID: "asset-6", description: "改变", keywords: []))
        }
        let reopened = try Store(url: url)
        let snapshot = try XCTUnwrap(reopened.snapshot(assetID: "asset-6"))
        XCTAssertEqual(snapshot.description, "原说明")
        XCTAssertEqual(snapshot.keywords, ["原标签"])
    }

    func testWriteIsVerifiedOnlyAfterReadbackContainsExpectedValues() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "asset-7", description: "AI 说明", keywords: ["海边", "夕阳"], sensitive: false)
        try store.saveSnapshot(assetID: "asset-7", description: "已有说明", keywords: ["家庭"])
        try store.beginWrite(assetID: "asset-7")
        XCTAssertThrowsError(try store.confirmWrite(assetID: "asset-7", description: "已有说明", keywords: ["海边", "夕阳"]))
        XCTAssertEqual(try store.result(assetID: "asset-7")?.writeState, .writing)
        try store.confirmWrite(assetID: "asset-7", description: "已有说明", keywords: ["家庭", "海边", "夕阳"])
        XCTAssertEqual(try store.result(assetID: "asset-7")?.writeState, .verified)
    }

    func testUndoReceiptOnlyIncludesKeywordsAddedBySuccessfulWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "asset-8", description: "AI说明", keywords: ["原标签", "新标签"], sensitive: false)
        try store.saveSnapshot(assetID: "asset-8", description: "原说明", keywords: ["原标签"])
        try store.beginWrite(assetID: "asset-8")
        try store.confirmWrite(assetID: "asset-8", description: "原说明", keywords: ["原标签", "新标签"])
        let receipt = try XCTUnwrap(store.writeReceipt(assetID: "asset-8"))
        XCTAssertEqual(receipt.addedKeywords, ["新标签"])
        XCTAssertEqual(receipt.status, "ready")
        try store.beginUndo(assetID: "asset-8")
        XCTAssertThrowsError(try store.finishUndo(assetID: "asset-8", description: "原说明", keywords: []))
        try store.finishUndo(assetID: "asset-8", description: "原说明", keywords: ["原标签"])
        XCTAssertEqual(try store.writeReceipt(assetID: "asset-8")?.status, "undone")
    }

    func testEditingOnlyAllowedBeforeSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "asset-9", description: "原 AI 描述", keywords: ["海"], sensitive: false)
        try store.editPending(assetID: "asset-9", description: "身份证", keywords: ["文件"])
        XCTAssertEqual(try store.result(assetID: "asset-9")?.sensitive, true)
        XCTAssertThrowsError(try store.editPending(assetID: "asset-9", description: "", keywords: ["海"]))
        try store.editPending(assetID: "asset-9", description: "人工描述", keywords: ["海", "日落", "海"])
        XCTAssertEqual(try store.result(assetID: "asset-9")?.keywords, ["海", "日落"])
        XCTAssertEqual(try store.result(assetID: "asset-9")?.description, "人工描述")
        try store.saveSnapshot(assetID: "asset-9", description: "", keywords: [])
        XCTAssertThrowsError(try store.editPending(assetID: "asset-9", description: "再次修改", keywords: ["新词"]))
    }

}
