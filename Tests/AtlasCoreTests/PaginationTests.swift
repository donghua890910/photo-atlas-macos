import XCTest
@testable import AtlasCore

final class PaginationTests: XCTestCase {
    func testLastPageNeverGoesBeyondCount() {
        XCTAssertEqual(Pagination.range(offset: 96, pageSize: 48, total: 100), 96..<100)
        XCTAssertEqual(Pagination.range(offset: 200, pageSize: 48, total: 100), 96..<100)
        XCTAssertEqual(Pagination.range(offset: 0, pageSize: 48, total: 0), 0..<0)
    }
}
