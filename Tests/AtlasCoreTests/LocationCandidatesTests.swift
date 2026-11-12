import XCTest
@testable import AtlasCore

final class LocationCandidatesTests: XCTestCase {
    func testLocationStatesStaySeparateFromAIAndWriteState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .coordinatesNoLocalAddress, keywords: []))
        XCTAssertEqual(try store.locationCandidates(assetID: id)?.status, .coordinatesNoLocalAddress)
        XCTAssertNil(try store.result(assetID: id))
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["中国", "示例省", "中国"]))
        XCTAssertEqual(try store.locationCandidates(assetID: id)?.keywords, ["中国", "示例省"])
        XCTAssertThrowsError(try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .noCoordinates, keywords: ["猜测地点"])))
    }

    func testLocationWriteJournalSeparatesSourcesAndProtectsOriginalKeywords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["中国", "示例省"]))
        let operation = try XCTUnwrap(store.prepareLocationWrite(assetID: id, description: "原说明", keywords: ["中国", "家庭"]))
        XCTAssertEqual(operation.addedKeywords, ["示例省"])
        XCTAssertNil(try store.latestPeopleOperation(assetID: id))
        XCTAssertEqual(try store.latestLocationOperation(assetID: id)?.id, operation.id)
        XCTAssertThrowsError(try store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["中国", "家庭"]))
        XCTAssertThrowsError(try store.saveSnapshot(assetID: id, description: "原说明", keywords: ["中国", "家庭"]))
        try store.beginPeopleWrite(operationID: operation.id)
        try store.markPeopleWriteReturned(operationID: operation.id)
        try store.confirmPeopleWrite(operationID: operation.id, description: "原说明", keywords: ["中国", "家庭", "示例省"])
        try store.beginPeopleUndo(operationID: operation.id)
        XCTAssertThrowsError(try store.confirmPeopleUndo(operationID: operation.id, description: "原说明", keywords: ["家庭"]))
        try store.confirmPeopleUndo(operationID: operation.id, description: "原说明", keywords: ["中国", "家庭"])
        XCTAssertEqual(try store.latestLocationOperation(assetID: id)?.state, "undone")
    }

    func testLocationWriteRequiresTrustedAddressAndRespectsManualProhibition() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["中国"]))
        XCTAssertThrowsError(try store.prepareLocationWrite(assetID: id, description: "", keywords: []))
        try store.cache(assetID: id, description: "照片", keywords: ["文件"], sensitive: true)
        try store.markPendingSensitive(assetID: id)
        XCTAssertThrowsError(try store.prepareLocationWrite(assetID: id, description: "", keywords: []))
    }

    func testInterruptedLocationWriteNeedsVerificationAndCannotAutoUndo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        let operationID: String
        do {
            let store = try Store(url: url)
            try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
            try store.recordLocationCandidates(assetID: id, value: LocationCandidates(status: .localAddress, keywords: ["中国"]))
            operationID = try XCTUnwrap(store.prepareLocationWrite(assetID: id, description: "原说明", keywords: ["原词"])).id
            try store.beginPeopleWrite(operationID: operationID)
        }
        let store = try Store(url: url)
        try store.markPeopleNeedsVerification(operationID: operationID)
        try store.confirmPeopleWrite(operationID: operationID, description: "原说明", keywords: ["原词", "中国"])
        XCTAssertFalse(try XCTUnwrap(store.latestLocationOperation(assetID: id)).undoEligible)
        XCTAssertThrowsError(try store.beginPeopleUndo(operationID: operationID))
    }
}
