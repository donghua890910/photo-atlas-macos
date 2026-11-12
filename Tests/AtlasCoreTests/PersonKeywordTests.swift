import XCTest
@testable import AtlasCore

final class PersonKeywordTests: XCTestCase {
    func testAddsNamedPeopleWithoutReplacingExistingKeywords() {
        let plan = PersonKeywords.plan(existing: ["旅行", "小明"], names: ["小明", "小红", "_UNKNOWN_", "  ", "小红"])
        XCTAssertEqual(plan.additions, ["小红"])
        XCTAssertEqual(plan.merged, ["旅行", "小明", "小红"])
    }

    func testCanonicalEquivalentNameIsNotDuplicated() {
        let plan = PersonKeywords.plan(existing: ["José"], names: ["Jose\u{301}"])
        XCTAssertEqual(plan.additions, [])
    }
}
