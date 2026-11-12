import Foundation

public struct PersonKeywordPlan {
    public let additions: [String]
    public let merged: [String]
}

public enum PersonKeywords {
    public static func assetUUID(for localIdentifier: String) -> UUID? {
        let parts = localIdentifier.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, let uuid = UUID(uuidString: String(parts[0])),
              uuid.uuidString.caseInsensitiveCompare(String(parts[0])) == .orderedSame else { return nil }
        return uuid
    }

    /// Plans additions from Photos metadata; it does not verify identities or write to Photos.
    public static func plan(existing: [String], names: [String]) -> PersonKeywordPlan {
        var seen = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping })
        var additions: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "_UNKNOWN_" else { continue }
            if seen.insert(name.precomposedStringWithCanonicalMapping).inserted {
                additions.append(name)
            }
        }
        return PersonKeywordPlan(additions: additions, merged: existing + additions)
    }
}
