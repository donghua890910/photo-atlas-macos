import Foundation

/// Conservative local rules supplement the model; they cannot detect every private document.
enum SensitiveContent {
    static func requiresReview(description: String, keywords: [String], category: String?) -> Bool {
        let text = ([description] + keywords + [category ?? ""]).joined(separator: " ")
        let privateTerms = ["身份证", "护照", "银行卡", "信用卡", "病历", "医疗", "诊断", "处方", "账单", "支付凭证", "银行账号", "个人信息", "社保卡", "医保卡", "驾驶证"]
        if privateTerms.contains(where: text.contains) { return true }
        let documentTerms = ["跟进表", "统计表", "业务统计", "订单报表", "绩效表", "财务报表", "工资表"]
        let privateFields = ["负责人", "订单数", "业绩", "工资", "账号", "收入", "金额", "达成率"]
        return documentTerms.contains(where: text.contains) && privateFields.contains(where: text.contains)
    }
}
