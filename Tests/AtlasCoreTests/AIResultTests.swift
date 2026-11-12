import XCTest
@testable import AtlasCore

final class AIResultTests: XCTestCase {
    func testStringKeywordsAreNormalizedWithoutAnotherInference() throws {
        let json = #"{"description":"海边的日落","keywords":"海边，夕阳、海边;旅行","sensitive":false,"category":"风景"}"#
        let result = try AIResult.parse(json)
        XCTAssertEqual(result.keywords, ["海边", "夕阳", "旅行"])
        XCTAssertFalse(result.sensitive)
    }

    func testMissingSensitiveFlagIsNotTreatedAsSafe() throws {
        let json = #"{"description":"一张文档","keywords":["文档"]}"#
        XCTAssertThrowsError(try AIResult.parse(json))
    }

    func testSensitiveDocumentTermsBlockWriteEvenIfModelSaysSafe() throws {
        let json = #"{"description":"一张银行卡","keywords":["卡片"],"sensitive":false}"#
        XCTAssertTrue(try AIResult.parse(json).sensitive)
    }

    func testPrivateBusinessTablesAreBlockedWithoutBlockingPublicStreetSigns() throws {
        let document = #"{"description":"项目跟进表包含各区域负责人、总目标和订单数。","keywords":["跟进表","达成率"],"category":"业务统计","sensitive":false}"#
        XCTAssertTrue(try AIResult.parse(document).sensitive)
        let street = #"{"description":"沿街商铺招牌上有公开联系电话。","keywords":["商店","街景"],"category":"商业街景","sensitive":false}"#
        XCTAssertFalse(try AIResult.parse(street).sensitive)
        let category = #"{"description":"一张单据","keywords":["单据"],"category":"医疗费用","sensitive":false}"#
        XCTAssertTrue(try AIResult.parse(category).sensitive)
    }
}
