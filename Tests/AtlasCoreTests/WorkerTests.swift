import Foundation
import XCTest
@testable import AtlasCore

final class WorkerTests: XCTestCase {
    func testWorkerCachesResultAndCompletesTask() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "example", kind: .ai, priority: 1)
        let engine = try ProcessingEngine(url: url, preview: { _ in Data([1]) }, analyze: { _ in
            try AIResult.parse(#"{"description":"测试","keywords":["照片"],"sensitive":false}"#)
        }, clock: { 100 })
        let outcome = await engine.runOne()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try store.result(assetID: "example")?.description, "测试")
        let idle = await engine.runOne()
        XCTAssertEqual(idle, .idle)
    }
    func testWorkerDefersWhenPreviewIsUnavailable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "unavailable", kind: .ai, priority: 1)
        let engine = try ProcessingEngine(url: url, preview: { _ in throw URLError(.resourceUnavailable) }, analyze: { _ in
            try AIResult.parse(#"{"description":"测试","keywords":["照片"],"sensitive":false}"#)
        }, clock: { 100 })
        let outcome = await engine.runOne()
        XCTAssertEqual(outcome, .deferred)
        XCTAssertNil(try store.result(assetID: "unavailable"))
        XCTAssertEqual(try store.outstanding(kind: .ai), 1)
        let idle = await engine.runOne()
        XCTAssertEqual(idle, .idle)
    }

    func testMissingLocalPreviewIsSkippedInsteadOfRetriedForever() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "cloud", kind: .ai, priority: 1)
        let engine = try ProcessingEngine(url: url, preview: { _ in throw PreviewFailure.noLocalPreview }, analyze: { _ in
            try AIResult.parse(#"{"description":"测试","keywords":["照片"],"sensitive":false}"#)
        }, clock: { 100 })
        let outcome = await engine.runOne()
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(try store.outstanding(kind: .ai), 0)
    }

}
