import XCTest
@testable import AtlasCore

final class IndexingEngineTests: XCTestCase {
    private let asset = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"

    func testMetadataSurvivesAIFailureAndDoesNotCountAsPhotosWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueueIndexAssets([asset])
        try store.enqueueAIAssets([asset], priority: 10)
        let index = try IndexingEngine(url: url, lookup: { _ in PhotoIndexCandidates(names: ["小明"], location: LocationCandidates(status: .localAddress, keywords: ["中国"])) }, clock: { 100 })
        let ai = try ProcessingEngine(url: url, preview: { _ in Data([1]) }, analyze: { _ in throw URLError(.cannotConnectToHost) }, clock: { 100 })
        let indexed = await index.runOne()
        let failedAI = await ai.runOne()
        XCTAssertEqual(indexed, .completed)
        XCTAssertEqual(failedAI, .deferred)
        XCTAssertEqual(try store.personCandidates(assetID: asset), ["小明"])
        XCTAssertEqual(try store.locationCandidates(assetID: asset)?.keywords, ["中国"])
        XCTAssertNil(try store.result(assetID: asset))
        XCTAssertEqual(try store.statistics().verifiedWrites, 0)
        XCTAssertEqual(try store.scanProgress().indexed, 1)
        XCTAssertEqual(try store.scanProgress().pending, 1)
    }

    func testIndexDoesNotRequireRerunningCachedAIAndInvalidAddressRollsBackNames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.cache(assetID: asset, description: "原AI", keywords: ["家庭"], sensitive: false)
        XCTAssertEqual(try store.enqueueAIAssets([asset], priority: 10), 0)
        XCTAssertEqual(try store.enqueueIndexAssets([asset, asset]), 1)
        let task = try XCTUnwrap(store.claimNext(now: 100, leaseSeconds: 300, kind: .gps))
        XCTAssertThrowsError(try store.cacheAndFinishIndex(id: task.id, token: task.token, now: 101,
            value: PhotoIndexCandidates(names: ["新名称"], location: LocationCandidates(status: .noCoordinates, keywords: ["假地址"]))))
        XCTAssertNil(try store.personCandidates(assetID: asset))
        XCTAssertEqual(try store.taskState(id: task.id), "running")
        XCTAssertThrowsError(try store.cacheAndFinishIndex(id: task.id, token: "wrong", now: 101,
            value: PhotoIndexCandidates(names: [], location: LocationCandidates(status: .noCoordinates, keywords: []))))
        XCTAssertThrowsError(try store.cacheAndFinishIndex(id: task.id, token: task.token, now: 400,
            value: PhotoIndexCandidates(names: [], location: LocationCandidates(status: .noCoordinates, keywords: []))))
        try store.cacheAndFinishIndex(id: task.id, token: task.token, now: 101,
            value: PhotoIndexCandidates(names: [], location: LocationCandidates(status: .noCoordinates, keywords: [])))
        XCTAssertEqual(try store.result(assetID: asset)?.description, "原AI")
        XCTAssertEqual(try store.scanProgress().indexed, 1)
    }

    func testLookupFailureRetriesWithoutInventingNoGPSStatus() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        try store.enqueueIndexAssets([asset])
        let index = try IndexingEngine(url: url, lookup: { _ in throw PeopleClientError.unavailable }, clock: { 100 })
        let failed = await index.runOne()
        let cooled = await index.runOne()
        XCTAssertEqual(failed, .deferred)
        XCTAssertEqual(cooled, .idle)
        XCTAssertNil(try store.locationCandidates(assetID: asset))
        XCTAssertEqual(try store.scanProgress().indexed, 0)
        XCTAssertEqual(try store.scanProgress().pendingIndex, 1)
    }
}
