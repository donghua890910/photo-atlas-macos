import XCTest
@testable import AtlasCore

final class PhotosAdapterTests: XCTestCase {
    func testParseMetadataRequiresExactIdentifier() throws {
        let data = Data(#"{"id":"a/L0/001","description":"原说明","keywords":["家庭"]}"#.utf8)
        let value = try PhotosAdapter.parse(data, expectedID: "a/L0/001")
        XCTAssertEqual(value.keywords, ["家庭"])
        XCTAssertThrowsError(try PhotosAdapter.parse(data, expectedID: "a/L0/000"))
    }
    func testParseRejectsMalformedMetadata() {
        XCTAssertThrowsError(try PhotosAdapter.parse(Data(#"{"id":"a","keywords":[]}"#.utf8), expectedID: "a"))
    }
    func testPeopleUndoRejectsRemovalOfOriginalKeyword() {
        let op = PeopleWriteOperation(id: "op", assetID: "asset", beforeDescription: "", beforeKeywords: ["原有"], addedKeywords: ["原有"], afterKeywords: ["原有"], writeReturned: true, undoEligible: true, state: "verified")
        XCTAssertThrowsError(try PhotosAdapter.undoPeople(id: "asset", operation: op))
    }

}
