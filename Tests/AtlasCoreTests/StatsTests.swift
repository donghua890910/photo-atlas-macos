import XCTest
@testable import AtlasCore

final class StatsTests: XCTestCase {
    func testStatisticsSeparateCachedVerifiedAndSensitive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "one", description: "照片", keywords: ["风景"], sensitive: false)
        try store.cache(assetID: "two", description: "文件", keywords: ["文件"], sensitive: true)
        let stats = try store.statistics()
        XCTAssertEqual(stats.aiCached, 2)
        XCTAssertEqual(stats.verifiedWrites, 0)
        XCTAssertEqual(stats.sensitive, 1)
        XCTAssertEqual(stats.pendingWrites, 2)
    }
}
