import XCTest
@testable import AtlasCore

final class ScanControlTests: XCTestCase {
    func testPausePersistsAndCountsAreSeparate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            XCTAssertFalse(try store.scanEnabled())
            try store.enqueueAIAssets(["one", "two"], priority: 1)
            try store.setScanEnabled(true)
            let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 600, kind: .ai))
            try store.markNoLocalPreview(id: task.id, token: task.token, now: 101)
            try store.setScanEnabled(false)
        }
        let store = try Store(url: url)
        let progress = try store.scanProgress()
        XCTAssertFalse(progress.enabled)
        XCTAssertEqual(progress.pending, 1)
        XCTAssertEqual(progress.skipped, 1)
        XCTAssertEqual(progress.done, 0)
        try store.setScanEnabled(true)
        XCTAssertNotNil(try store.claimNext(now: 102, leaseSeconds: 600, kind: .ai))
    }
}
