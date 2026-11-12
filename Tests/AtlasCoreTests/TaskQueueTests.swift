import XCTest
@testable import AtlasCore

final class TaskQueueTests: XCTestCase {
    func testExpiredAILeaseCanRetryButWriteNeedsVerification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "a", kind: .ai, priority: 10)
        let first = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 30))
        XCTAssertEqual(first.kind, .ai)
        XCTAssertNil(try store.claimNext(now: 110, leaseSeconds: 30))
        let retried = try XCTUnwrap(store.claimNext(now: 131, leaseSeconds: 30))
        XCTAssertNotEqual(first.token, retried.token)
        XCTAssertThrowsError(try store.finishTask(id: first.id, token: first.token, now: 132))
        XCTAssertThrowsError(try store.finishTask(id: retried.id, token: retried.token, now: 132))
        try store.cache(assetID: "a", description: "说明", keywords: ["照片"], sensitive: false)
        try store.finishTask(id: retried.id, token: retried.token, now: 132)

        try store.cache(assetID: "b", description: "说明", keywords: ["照片"], sensitive: false)
        try store.saveSnapshot(assetID: "b", description: "", keywords: [])
        try store.enqueue(assetID: "b", kind: .write, priority: 20)
        let write = try XCTUnwrap(store.claimNext(now: 200, leaseSeconds: 30))
        XCTAssertEqual(write.kind, .write)
        XCTAssertEqual(try store.result(assetID: "b")?.writeState, .writing)
        XCTAssertThrowsError(try store.finishTask(id: write.id, token: write.token, now: 201))
        XCTAssertNil(try store.claimNext(now: 231, leaseSeconds: 30))
        XCTAssertEqual(try store.taskState(id: write.id), "needs_verification")
        XCTAssertEqual(try store.result(assetID: "b")?.writeState, .needsVerification)
        XCTAssertThrowsError(try store.finishTask(id: write.id, token: write.token, now: 232))
    }

    func testWritingRequiresCachedResultAndOriginalSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        XCTAssertThrowsError(try store.enqueue(assetID: "missing", kind: .write, priority: 1))
    }
    func testFailureUsesCooldownAndDoesNotRetryImmediately() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "x", kind: .ai, priority: 1)
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 30))
        try store.failTask(id: task.id, token: task.token, now: 110)
        XCTAssertNil(try store.claimNext(now: 115, leaseSeconds: 30))
        XCTAssertNotNil(try store.claimNext(now: 140, leaseSeconds: 30))
    }

    func testAIResultAndCompletionAreCommittedTogether() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "y", kind: .ai, priority: 1)
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 30))
        XCTAssertThrowsError(try store.cacheAndFinishAI(id: task.id, token: "wrong", now: 110, description: "说明", keywords: ["标签"], sensitive: false))
        XCTAssertNil(try store.result(assetID: "y"))
        try store.cacheAndFinishAI(id: task.id, token: task.token, now: 110, description: "说明", keywords: ["标签"], sensitive: false)
        XCTAssertEqual(try store.result(assetID: "y")?.description, "说明")
        XCTAssertEqual(try store.taskState(id: task.id), "done")
    }

    func testWorkerCanClaimOnlySupportedKind() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueue(assetID: "gps", kind: .gps, priority: 10)
        try store.enqueue(assetID: "ai", kind: .ai, priority: 1)
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 30, kind: .ai))
        XCTAssertEqual(task.kind, .ai)
        XCTAssertNil(try store.claimNext(now: 100, leaseSeconds: 30, kind: .ai))
    }

    func testOutstandingCountsOnlyPendingAndRunningTasks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        XCTAssertEqual(try store.outstanding(kind: .ai), 0)
        try store.enqueue(assetID: "a", kind: .ai, priority: 1)
        XCTAssertEqual(try store.outstanding(kind: .ai), 1)
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 30, kind: .ai))
        try store.cacheAndFinishAI(id: task.id, token: task.token, now: 110, description: "说明", keywords: ["照片"], sensitive: false)
        XCTAssertEqual(try store.outstanding(kind: .ai), 0)
    }

    func testInterruptedWriteRemainsUncertainAcrossRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var taskID: Int64 = 0
        do {
            let store = try Store(url: url)
            try store.cache(assetID: "restart", description: "说明", keywords: ["关键词"], sensitive: false)
            try store.saveSnapshot(assetID: "restart", description: "", keywords: [])
            try store.enqueue(assetID: "restart", kind: .write, priority: 1)
            taskID = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 10)).id
        }
        let reopened = try Store(url: url)
        XCTAssertNil(try reopened.claimNext(now: 111, leaseSeconds: 10))
        XCTAssertEqual(try reopened.taskState(id: taskID), "needs_verification")
        XCTAssertEqual(try reopened.result(assetID: "restart")?.writeState, .needsVerification)
    }

    func testConcurrentConnectionsClaimOnlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try Store(url: url)
            try store.enqueue(assetID: "one", kind: .ai, priority: 1)
        }
        let claimed = await withTaskGroup(of: ClaimedTask?.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let store = try? Store(url: url) else { return nil }
                    return try? store.claimNext(now: 100, leaseSeconds: 30, kind: .ai)
                }
            }
            var total = 0
            for await task in group { if task != nil { total += 1 } }
            return total
        }
        XCTAssertEqual(claimed, 1)
    }

    func testBatchEnqueueIsIncrementalAndAtomic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "already", description: "说明", keywords: ["照片"], sensitive: false)
        XCTAssertEqual(try store.enqueueAIAssets(["already", "new", "new"], priority: 5), 1)
        XCTAssertEqual(try store.enqueueAIAssets(["new"], priority: 5), 0)
        XCTAssertThrowsError(try store.enqueueAIAssets(["other", ""], priority: 5))
        XCTAssertEqual(try store.outstanding(kind: .ai), 1)
    }

}
