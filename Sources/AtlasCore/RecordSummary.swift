import Foundation

public enum RecordFilter: String, CaseIterable, Sendable {
    case all, pending, verified, needsVerification, sensitive, metadata
}

public struct RecordSummary: Identifiable, Sendable {
    public let id: String
    public let description: String?
    public let keywords: [String]
    public let state: WriteState?
    public let sensitive: Bool
    public let people: [String]
    public let places: [String]
    public let updatedAt: String
    public let metadataNeedsVerification: Bool
    public let receiptStatus: String?
}
