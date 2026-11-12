import XCTest
@testable import AtlasCore

final class PersonCandidatesTests: XCTestCase {
    func testCandidatesAreSeparateFromAIAndWriteState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/040"
        try store.recordPersonCandidates(assetID: id, names: ["小明", "小明", "_UNKNOWN_"])
        XCTAssertEqual(try store.personCandidates(assetID: id), ["小明"])
        XCTAssertNil(try store.result(assetID: id))
        try store.recordPersonCandidates(assetID: id, names: [])
        XCTAssertEqual(try store.personCandidates(assetID: id), [])
    }

    func testRejectsInvalidResourceIdentifier() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        XCTAssertThrowsError(try store.recordPersonCandidates(assetID: "not-a-photo", names: ["人物"]))
    }
    func testAcceptingPeopleOnlyUpdatesPendingReviewResult() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭", "小明"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明", "小红"])
        XCTAssertEqual(try store.addPeopleToPendingResult(assetID: id), 1)
        let result = try XCTUnwrap(store.result(assetID: id))
        XCTAssertEqual(result.keywords, ["家庭", "小明", "小红"])
        XCTAssertEqual(result.writeState, .pending)
        try store.saveSnapshot(assetID: id, description: "", keywords: [])
        XCTAssertThrowsError(try store.addPeopleToPendingResult(assetID: id))
    }

    func testPersonWriteIsIndependentAndRequiresVerifiedReadback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.recordPersonCandidates(assetID: id, names: ["小明", "小红"])
        XCTAssertThrowsError(try store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["家庭"]))
        try store.cache(assetID: id, description: "AI说明", keywords: ["风景"], sensitive: false)
        try store.saveSnapshot(assetID: id, description: "原说明", keywords: ["家庭"])
        try store.beginWrite(assetID: id)
        try store.confirmWrite(assetID: id, description: "原说明", keywords: ["家庭", "风景"])
        let operation = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["家庭", "风景", "小明"]))
        XCTAssertEqual(operation.addedKeywords, ["小红"])
        try store.beginPeopleWrite(operationID: operation.id)
        XCTAssertThrowsError(try store.confirmPeopleWrite(operationID: operation.id, description: "原说明", keywords: ["风景", "小明", "小红"]))
        try store.confirmPeopleWrite(operationID: operation.id, description: "原说明", keywords: ["家庭", "风景", "小明", "小红"])
        XCTAssertEqual(try store.result(assetID: id)?.writeState, .verified)
        XCTAssertEqual(try store.peopleWriteState(operationID: operation.id), "verified")
    }

    func testPersonOperationBlocksCompetingAISnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        let operation = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "", keywords: []))
        XCTAssertThrowsError(try store.saveSnapshot(assetID: id, description: "", keywords: []))
        try store.beginPeopleWrite(operationID: operation.id)
        try store.confirmPeopleWrite(operationID: operation.id, description: "", keywords: ["小明"])
        try store.saveSnapshot(assetID: id, description: "", keywords: ["小明"])
    }

    func testOnlyUnstartedPersonOperationCanBeCancelled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        let first = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "", keywords: []))
        try store.cancelPreparedPeopleWrite(operationID: first.id)
        let second = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "", keywords: []))
        try store.beginPeopleWrite(operationID: second.id)
        XCTAssertThrowsError(try store.cancelPreparedPeopleWrite(operationID: second.id))
    }

    func testPeopleUndoPreservesOriginalKeywordsAndRequiresReadback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.recordPersonCandidates(assetID: id, names: ["小明", "小红"])
        let operation = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["家庭", "小明"]))
        try store.beginPeopleWrite(operationID: operation.id)
        try store.markPeopleWriteReturned(operationID: operation.id)
        try store.confirmPeopleWrite(operationID: operation.id, description: "原说明", keywords: ["家庭", "小明", "小红"])
        try store.beginPeopleUndo(operationID: operation.id)
        XCTAssertThrowsError(try store.confirmPeopleUndo(operationID: operation.id, description: "原说明", keywords: ["家庭"]))
        try store.confirmPeopleUndo(operationID: operation.id, description: "原说明", keywords: ["家庭", "小明"])
        XCTAssertEqual(try store.peopleWriteState(operationID: operation.id), "undone")
    }

    func testAIUndoAndPeopleWriteCannotOverlap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try Store(url: url)
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
        try store.saveSnapshot(assetID: id, description: "", keywords: [])
        try store.beginWrite(assetID: id)
        try store.confirmWrite(assetID: id, description: "照片", keywords: ["家庭"])
        try store.recordPersonCandidates(assetID: id, names: ["小明"])
        let operation = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "照片", keywords: ["家庭"]))
        XCTAssertThrowsError(try store.beginUndo(assetID: id))
        try store.beginPeopleWrite(operationID: operation.id)
        try store.confirmPeopleWrite(operationID: operation.id, description: "照片", keywords: ["家庭", "小明"])
        try store.beginUndo(assetID: id)
        XCTAssertThrowsError(try store.preparePeopleWrite(assetID: id, description: "照片", keywords: ["家庭"]))
    }

    func testInterruptedPersonWriteCannotBeUndoneAutomatically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        let operationID: String
        do {
            let store = try Store(url: url)
            try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
            try store.recordPersonCandidates(assetID: id, names: ["小明"])
            operationID = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["原词"])).id
            try store.beginPeopleWrite(operationID: operationID)
        }
        do {
            let store = try Store(url: url)
            try store.markPeopleNeedsVerification(operationID: operationID)
            try store.confirmPeopleWrite(operationID: operationID, description: "原说明", keywords: ["原词", "小明"])
            let verified = try XCTUnwrap(store.peopleOperation(id: operationID))
            XCTAssertFalse(verified.undoEligible)
            XCTAssertThrowsError(try store.beginPeopleUndo(operationID: operationID))
        }
    }

    func testInterruptedPeopleUndoRequiresVerification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("atlas.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001"
        let operationID: String
        do {
            let store = try Store(url: url)
            try store.cache(assetID: id, description: "照片", keywords: ["家庭"], sensitive: false)
            try store.recordPersonCandidates(assetID: id, names: ["小明"])
            operationID = try XCTUnwrap(store.preparePeopleWrite(assetID: id, description: "原说明", keywords: ["原词"])).id
            try store.beginPeopleWrite(operationID: operationID)
            try store.markPeopleWriteReturned(operationID: operationID)
            try store.confirmPeopleWrite(operationID: operationID, description: "原说明", keywords: ["原词", "小明"])
            try store.beginPeopleUndo(operationID: operationID)
        }
        let store = try Store(url: url)
        try store.markPeopleUndoUncertain(operationID: operationID)
        XCTAssertThrowsError(try store.confirmPeopleUndo(operationID: operationID, description: "被修改", keywords: ["原词"]))
        try store.confirmPeopleUndo(operationID: operationID, description: "原说明", keywords: ["原词"])
        XCTAssertEqual(try store.peopleWriteState(operationID: operationID), "undone")
    }

}
