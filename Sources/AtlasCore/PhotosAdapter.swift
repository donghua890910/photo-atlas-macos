import Foundation
import Darwin

public struct PhotoMetadata: Codable, Sendable {
    public let id: String
    public let description: String
    public let keywords: [String]
}

public enum PhotosAdapter {
    private static let script = #"""
ObjC.import('Foundation');
const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
const input = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
const item = Application('Photos').mediaItems.byId(input.id);
function read() {
  return {id: item.id(), description: item.description() || '', keywords: item.keywords() || []};
}
let current = read();
if (current.id !== input.id) throw Error('identity mismatch');
if (input.mode === 'write') {
  if (current.description !== input.before.description || JSON.stringify(current.keywords) !== JSON.stringify(input.before.keywords)) throw Error('metadata changed');
  let merged = current.keywords.slice();
  for (const word of input.keywords) if (!merged.some(existing => existing.normalize("NFC") === word.normalize("NFC"))) merged.push(word);
  if (current.description === '' && input.description !== '') item.description = input.description;
  if (merged.length !== current.keywords.length) item.keywords = merged;
  current = read();
} else if (input.mode === 'undo') {
  if (current.description !== input.before.description || JSON.stringify(current.keywords) !== JSON.stringify(input.before.keywords)) throw Error('metadata changed');
  const updated = current.keywords.filter(word => !input.remove.includes(word));
  if (updated.length !== current.keywords.length) item.keywords = updated;
  current = read();
}
JSON.stringify(current);
"""#

    public static func parse(_ data: Data, expectedID: String) throws -> PhotoMetadata {
        let metadata = try JSONDecoder().decode(PhotoMetadata.self, from: data)
        guard !expectedID.isEmpty, metadata.id == expectedID else { throw StoreError.invalidInput }
        return metadata
    }

    public static func read(id: String) throws -> PhotoMetadata {
        try invoke(["mode": "read", "id": id], id: id)
    }

    public static func write(id: String, before: PhotoMetadata, description: String, keywords: [String]) throws -> PhotoMetadata {
        guard id == before.id, !keywords.isEmpty else { throw StoreError.invalidInput }
        let beforeObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(before))
        return try invoke(["mode": "write", "id": id, "before": beforeObject, "description": description, "keywords": keywords], id: id)
    }

    public static func undo(id: String, receipt: WriteReceipt) throws -> PhotoMetadata {
        guard receipt.status == "ready", !receipt.addedKeywords.isEmpty else { throw StoreError.invalidTransition }
        let before: [String: Any] = ["description": receipt.description, "keywords": receipt.keywords]
        return try invoke(["mode": "undo", "id": id, "before": before, "remove": receipt.addedKeywords], id: id)
    }

    public static func undoPeople(id: String, operation: PeopleWriteOperation) throws -> PhotoMetadata {
        guard operation.assetID == id, operation.state == "verified", operation.undoEligible, let after = operation.afterKeywords,
              !operation.addedKeywords.isEmpty,
              Set(operation.addedKeywords).isDisjoint(with: Set(operation.beforeKeywords)),
              Set(operation.addedKeywords).isSubset(of: Set(after)),
              Set(operation.beforeKeywords).isSubset(of: Set(after)) else { throw StoreError.invalidTransition }
        let before: [String: Any] = ["description": operation.beforeDescription, "keywords": after]
        return try invoke(["mode": "undo", "id": id, "before": before, "remove": operation.addedKeywords], id: id)
    }

    private static func invoke(_ input: [String: Any], id: String) throws -> PhotoMetadata {
        let payload = try JSONSerialization.data(withJSONObject: input)
        guard payload.count <= 16_000 else { throw StoreError.invalidInput }
        let data = try ScriptProcess.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                         arguments: ["-l", "JavaScript", "-e", script], input: payload)
        return try parse(data, expectedID: id)
    }
}
