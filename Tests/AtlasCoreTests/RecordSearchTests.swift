import XCTest
@testable import AtlasCore

final class RecordSearchTests: XCTestCase {
    func testSearchFindsMetadataWithoutAIAndKeepsStatusesSeparate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["示例市"]))
        XCTAssertEqual(try store.records(query: "小明").map(\.id), [id])
        XCTAssertEqual(try store.records(query: "示例").map(\.id), [id])
        XCTAssertNil(try store.records().first?.state)
        XCTAssertEqual(try store.records(filter: .verified).count, 0)
        try store.cache(assetID: id, description: "海边散步", keywords: ["家庭"], sensitive: false)
        try store.cache(assetID: "sensitive", description: "文档", keywords: ["文件"], sensitive: true)
        XCTAssertEqual(try store.records(filter: .all).count, 2)
        XCTAssertEqual(Set(try store.records(filter: .pending).map(\.id)), Set([id, "sensitive"]))
        XCTAssertEqual(try store.records(filter: .sensitive).map(\.id), ["sensitive"])
        XCTAssertEqual(try store.records(query: "散步").map(\.id), [id])
        XCTAssertEqual(try store.records(filter: .metadata).map(\.id), [id])
    }

    func testSearchTreatsWildcardsAndSQLAsLiteralTextAndPaginates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "a", description: "100%_literal", keywords: ["照片"], sensitive: false)
        try store.cache(assetID: "b", description: "普通照片", keywords: ["照片"], sensitive: false)
        XCTAssertEqual(try store.records(query: "%_").map(\.id), ["a"])
        XCTAssertEqual(try store.records(query: "' OR 1=1 --").count, 0)
        let first = try XCTUnwrap(store.records(limit: 1).first)
        let second = try XCTUnwrap(store.records(limit: 1, offset: 1).first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertThrowsError(try store.records(limit: 0))
        XCTAssertThrowsError(try store.records(offset: -1))
    }

    func testNeedsVerificationFilterIncludesInterruptedMetadataOperations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        let operation = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "", keywords: []))
        try store.beginPeopleWrite(operationID: operation.id)
        try store.markPeopleNeedsVerification(operationID: operation.id)
        XCTAssertEqual(try store.records(filter: .needsVerification).map(\.id), [id])
        XCTAssertTrue(try XCTUnwrap(store.records(filter: .needsVerification).first).metadataNeedsVerification)
        XCTAssertEqual(try store.result(assetID: id)?.writeState, .pending)
    }

    func testUncertainAIUndoAppearsInReviewFilter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "photo", description: "照片", keywords: ["家庭"], sensitive: false)
        try store.saveSnapshot(assetID: "photo", description: "", keywords: [])
        try store.beginWrite(assetID: "photo")
        try store.confirmWrite(assetID: "photo", description: "照片", keywords: ["家庭"])
        try store.beginUndo(assetID: "photo")
        try store.markUndoNeedsReview(assetID: "photo")
        XCTAssertEqual(try store.records(filter: .needsVerification).first?.receiptStatus, "needs_review")
    }
}
