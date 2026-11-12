import XCTest
@testable import AtlasCore

final class LegacyResultsTests: XCTestCase {
    func testPreservesLegacyResultButDoesNotTreatAsVerifiedCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("v8_ai_results.jsonl")
        try #"{"uuid":"old-id","description":"说明","keywords":["标签"],"sensitive":false}"#.appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let store = try Store(url: dir.appendingPathComponent("atlas.sqlite"))
        XCTAssertEqual(try store.importLegacyResults(from: file), 1)
        XCTAssertEqual(try store.legacyResultCount(assetID: "old-id"), 1)
        XCTAssertNil(try store.result(assetID: "old-id"))
        XCTAssertEqual(try store.importLegacyResults(from: file), 1)
        XCTAssertEqual(try store.legacyResultCount(assetID: "old-id"), 1)
    }

    func testInvalidLineRollsBackWholeImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("v8_ai_results.jsonl")
        try "{\"uuid\":\"old-id\"}\n".write(to: file, atomically: true, encoding: .utf8)
        let store = try Store(url: dir.appendingPathComponent("atlas.sqlite"))
        _ = try store.importLegacyResults(from: file)
        try "{\"uuid\":\"other\"}\ninvalid\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.importLegacyResults(from: file))
        XCTAssertEqual(try store.legacyResultCount(assetID: "old-id"), 1)
        XCTAssertEqual(try store.legacyResultCount(assetID: "other"), 0)
    }
    func testLegacySuggestionUsesActualIdentifierPrefixAndRemainsUnverified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let uuid = "A1B2C3D4-1111-4222-8333-123456789ABC"
        let file = dir.appendingPathComponent("v8_ai_results.jsonl")
        let row = "{\"uuid\":\"\(uuid)\",\"description\":\"旧结果\",\"keywords\":[\"照片\"],\"sensitive\":false}\n"
        try row.write(to: file, atomically: true, encoding: .utf8)
        let store = try Store(url: dir.appendingPathComponent("atlas.sqlite"))
        _ = try store.importLegacyResults(from: file)
        let suggestion = try XCTUnwrap(store.legacySuggestion(localIdentifier: uuid + "/L0/040"))
        XCTAssertEqual(suggestion.result.description, "旧结果")
        XCTAssertEqual(suggestion.source, "v8_ai_results.jsonl")
        XCTAssertNil(try store.result(assetID: uuid + "/L0/040"))
        try store.cache(assetID: uuid + "/L0/040", description: suggestion.result.description, keywords: suggestion.result.keywords, sensitive: suggestion.result.sensitive, origin: "legacy:\(suggestion.source):\(suggestion.line)")
        let cached = try XCTUnwrap(store.result(assetID: uuid + "/L0/040"))
        XCTAssertEqual(cached.writeState, .pending)
        XCTAssertTrue(cached.origin.hasPrefix("legacy:"))
        XCTAssertNil(try store.legacySuggestion(localIdentifier: "invalid/L0/001"))
    }

}
