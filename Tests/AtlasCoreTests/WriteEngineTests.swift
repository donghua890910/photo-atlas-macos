import XCTest
@testable import AtlasCore

private actor TestPhoto {
    var metadata = PhotoMetadata(id: "photo", description: "原说明", keywords: ["原词"])
    var writes = 0
    func read() -> PhotoMetadata { metadata }
    func write(description: String, keywords: [String]) {
        writes += 1
        metadata = PhotoMetadata(id: "photo", description: metadata.description.isEmpty ? description : metadata.description,
                                 keywords: metadata.keywords + keywords.filter { !metadata.keywords.contains($0) })
    }
    func change() { metadata = PhotoMetadata(id: "photo", description: "别人改过", keywords: ["原词"]) }
    func count() -> Int { writes }
}

private actor AvailablePhoto {
    private var metadata = PhotoMetadata(id: "available", description: "原说明", keywords: ["原词"])
    func read() -> PhotoMetadata { metadata }
    func write(keywords: [String]) {
        metadata = PhotoMetadata(id: "available", description: metadata.description, keywords: metadata.keywords + keywords)
    }
}

final class WriteEngineTests: XCTestCase {
    func testScanWritesSelectedSensitiveResultAndRespectsManualProhibition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = TestPhoto()
        try store.cache(assetID: "outside", description: "其他照片", keywords: ["风景"], sensitive: false)
        try store.cache(assetID: "sensitive", description: "银行卡", keywords: ["银行卡"], sensitive: false)
        try store.enqueueAIAssets(["sensitive", "photo"], priority: 10, automaticallyWrite: true)
        try store.markPendingSensitive(assetID: "sensitive")
        try store.setScanEnabled(true)
        let ai = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .ai))
        XCTAssertEqual(ai.assetID, "photo")
        try store.cacheAndFinishAI(id: ai.id, token: ai.token, now: 101, description: "AI说明", keywords: ["新词"], sensitive: true)
        let engine = try WriteEngine(url: url, read: { id in
            XCTAssertEqual(id, "photo")
            return await photo.read()
        }, write: { _, _, description, keywords in await photo.write(description: description, keywords: keywords) }, clock: { 102 })

        let prepared = await engine.runOne()
        XCTAssertEqual(prepared, .completed)
        let writesAfterPreparation = await photo.count()
        XCTAssertEqual(writesAfterPreparation, 0)
        XCTAssertEqual(try store.snapshot(assetID: "photo")?.keywords, ["原词"])
        let written = await engine.runOne()
        XCTAssertEqual(written, .completed)
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .verified)
        XCTAssertEqual(try store.writeReceipt(assetID: "photo")?.addedKeywords, ["新词"])
        XCTAssertEqual(try store.writeReceipt(assetID: "photo")?.description, "原说明")
        try store.enqueueAIAssets(["photo"], priority: 10, automaticallyWrite: true)
        let finished = await engine.runOne()
        XCTAssertEqual(finished, .idle)
        XCTAssertEqual(try store.scanProgress().outstanding, 0)
        XCTAssertNil(try store.snapshot(assetID: "outside"))
        XCTAssertNil(try store.snapshot(assetID: "sensitive"))
    }

    func testAutomaticWriteRequestSurvivesPauseBeforeSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "photo", description: "AI说明", keywords: ["新词"], sensitive: false)
        try store.enqueueAIAssets(["photo"], priority: 10, automaticallyWrite: true)
        try store.setScanEnabled(true)
        let engine = try WriteEngine(url: url, read: { id in
            try Store(url: url).setScanEnabled(false)
            return PhotoMetadata(id: id, description: "原说明", keywords: ["原词"])
        }, write: { _, _, _, _ in XCTFail("Paused scan must not write") })
        let paused = await engine.runOne()
        XCTAssertEqual(paused, .skipped)
        XCTAssertNil(try store.snapshot(assetID: "photo"))
        XCTAssertEqual(try store.scanProgress().pendingWrites, 1)
        let reopened = try Store(url: url)
        XCTAssertNil(try reopened.nextAutomaticWrite())
        try reopened.setScanEnabled(true)
        XCTAssertEqual(try reopened.nextAutomaticWrite(), "photo")
    }

    func testUnreadableAutomaticWriteDoesNotBlockOtherPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = AvailablePhoto()
        try store.cache(assetID: "unavailable", description: "说明", keywords: ["关键词"], sensitive: false)
        try store.cache(assetID: "available", description: "说明", keywords: ["关键词"], sensitive: false)
        try store.enqueueAIAssets(["unavailable", "available"], priority: 10, automaticallyWrite: true)
        try store.setScanEnabled(true)
        let engine = try WriteEngine(url: url, read: { id in
            if id == "unavailable" { throw URLError(.timedOut) }
            return await photo.read()
        }, write: { _, _, _, words in await photo.write(keywords: words) }, clock: { 100 })
        let failed = await engine.runOne()
        let prepared = await engine.runOne()
        let written = await engine.runOne()
        let deferred = await engine.runOne()
        XCTAssertEqual(failed, .skipped)
        XCTAssertEqual(prepared, .completed)
        XCTAssertEqual(written, .completed)
        XCTAssertEqual(deferred, .idle)
        XCTAssertEqual(try store.result(assetID: "unavailable")?.writeState, .pending)
        XCTAssertNil(try store.snapshot(assetID: "unavailable"))
        let outstanding = try await engine.hasOutstanding()
        XCTAssertTrue(outstanding)
    }

    func testExpiredTokenCannotCommitReceiptOrCompletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: "photo", description: "AI", keywords: ["新词"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .write))
        XCTAssertThrowsError(try store.confirmAndFinishWrite(task: task, now: 280, description: "原说明", keywords: ["原词", "新词"]))
        XCTAssertNil(try store.writeReceipt(assetID: "photo"))
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .writing)
        XCTAssertEqual(try store.taskState(id: task.id), "running")
        try store.confirmAndFinishWrite(task: task, now: 101, description: "原说明", keywords: ["原词", "新词"])
        XCTAssertEqual(try store.taskState(id: task.id), "done")
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .verified)
    }

    func testOnlyApprovedWriteRunsAndReadbackCommitsTaskAndReceipt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = TestPhoto()
        try store.cache(assetID: "photo", description: "AI说明", keywords: ["新词"], sensitive: false)
        let engine = try WriteEngine(url: url, read: { _ in await photo.read() }, write: { _, _, description, words in await photo.write(description: description, keywords: words) }, clock: { 100 })
        let unapproved = await engine.runOne()
        XCTAssertEqual(unapproved, .idle)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        XCTAssertEqual(try store.scanProgress().pendingWrites, 1)
        let written = await engine.runOne()
        XCTAssertEqual(written, .completed)
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .verified)
        XCTAssertEqual(try store.writeReceipt(assetID: "photo")?.addedKeywords, ["新词"])
        XCTAssertEqual(try store.writeReceipt(assetID: "photo")?.description, "原说明")
        XCTAssertEqual(try store.scanProgress().outstanding, 0)
        XCTAssertFalse(try store.hasQueuedWrite(assetID: "photo"))
        let idle = await engine.runOne()
        XCTAssertEqual(idle, .idle)
        let count = await photo.count()
        XCTAssertEqual(count, 1)
    }

    func testChangedPhotoStopsBeforeWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = TestPhoto()
        try store.cache(assetID: "photo", description: "AI", keywords: ["新词"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        await photo.change()
        let engine = try WriteEngine(url: url, read: { _ in await photo.read() }, write: { _, _, description, words in await photo.write(description: description, keywords: words) }, clock: { 100 })
        let outcome = await engine.runOne()
        XCTAssertEqual(outcome, .skipped)
        let count = await photo.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try store.scanProgress().uncertainWrites, 1)
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .needsVerification)
    }

    func testWriteTimeoutIsResolvedByReadbackWithoutRepeatingWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = TestPhoto()
        try store.cache(assetID: "photo", description: "AI", keywords: ["新词"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        let engine = try WriteEngine(url: url, read: { _ in await photo.read() }, write: { _, _, description, words in
            await photo.write(description: description, keywords: words)
            throw URLError(.timedOut)
        }, clock: { 100 })
        let written = await engine.runOne()
        let again = await engine.runOne()
        XCTAssertEqual(written, .completed)
        XCTAssertEqual(again, .idle)
        XCTAssertEqual(try store.statistics().verifiedWrites, 1)
        XCTAssertEqual(try store.scanProgress().uncertainWrites, 0)
        XCTAssertNil(try store.writeReceipt(assetID: "photo"))
        let count = await photo.count()
        XCTAssertEqual(count, 1)
    }

    func testRestartRecoversInterruptedTasksAndVerifiesExistingPhotosWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url), photo = TestPhoto()
        try store.cache(assetID: "photo", description: "AI", keywords: ["新词"], sensitive: false)
        try store.approveWrite(assetID: "photo", description: "原说明", keywords: ["原词"])
        try store.enqueue(assetID: "scan", kind: .ai, priority: 10)
        try store.enqueue(assetID: "index", kind: .gps, priority: 10)
        let writing = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .write))
        let scanning = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .ai))
        let indexing = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 180, kind: .gps))
        await photo.write(description: "AI", keywords: ["新词"])

        try store.setScanEnabled(true)
        try store.recoverInterruptedTasks()
        XCTAssertEqual(try store.taskState(id: scanning.id), "pending")
        XCTAssertEqual(try store.taskState(id: indexing.id), "pending")
        XCTAssertEqual(try store.taskState(id: writing.id), "needs_verification")
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .needsVerification)
        XCTAssertNil(try store.claimNext(now: 101, leaseSeconds: 180, kind: .write))

        let engine = try WriteEngine(url: url, read: { _ in await photo.read() }, write: { _, _, _, _ in
            XCTFail("Interrupted writes must only be read back")
        })
        try await engine.reconcileUncertainWrites()
        XCTAssertEqual(try store.taskState(id: writing.id), "done")
        XCTAssertEqual(try store.result(assetID: "photo")?.writeState, .verified)
        XCTAssertNil(try store.writeReceipt(assetID: "photo"))
    }
}
