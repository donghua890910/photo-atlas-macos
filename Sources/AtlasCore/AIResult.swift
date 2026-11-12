import Foundation

public struct AIResult: Decodable, Sendable {
    public let description: String
    public let keywords: [String]
    public let sensitive: Bool
    public let category: String?

    init(description: String, keywords: [String], sensitive: Bool, category: String?) {
        self.description = description
        self.keywords = keywords
        self.sensitive = sensitive
        self.category = category
    }

    private enum CodingKeys: String, CodingKey { case description, keywords, sensitive, category }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .description).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError.invalidInput }
        let rawWords: [String]
        if let array = try? container.decode([String].self, forKey: .keywords) {
            rawWords = array
        } else {
            let text = try container.decode(String.self, forKey: .keywords)
            rawWords = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n|"))
        }
        var seen = Set<String>()
        let words = rawWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !words.isEmpty else { throw StoreError.invalidInput }
        let declaredSensitive = try container.decode(Bool.self, forKey: .sensitive)
        let category = try container.decodeIfPresent(String.self, forKey: .category)
        self.description = text
        self.keywords = words
        self.sensitive = declaredSensitive || SensitiveContent.requiresReview(description: text, keywords: words, category: category)
        self.category = category
    }

    public static func parse(_ json: String) throws -> AIResult {
        try JSONDecoder().decode(AIResult.self, from: Data(json.utf8))
    }
}
