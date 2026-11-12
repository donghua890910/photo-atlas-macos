import Foundation
import AtlasCore

@main
struct PeopleWriteProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("backups/write-probes", isDirectory: true)
        let dbURL = folder.appendingPathComponent("people-" + UUID().uuidString + ".sqlite")
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["asset_id"] as? String else { throw StoreError.invalidInput }
            let before = try PhotosAdapter.read(id: id)
            let marker = "PhotoAtlas-人物测试-" + UUID().uuidString
            let db = try Store(url: dbURL)
            try db.cache(assetID: id, description: "临时测试", keywords: ["测试"], sensitive: false)
            try db.recordPersonCandidates(assetID: id, names: [marker])
            guard let operation = try db.preparePeopleWrite(assetID: id, description: before.description, keywords: before.keywords) else { throw StoreError.invalidTransition }
            try db.beginPeopleWrite(operationID: operation.id)
            _ = try PhotosAdapter.write(id: id, before: before, description: "", keywords: operation.addedKeywords)
            try db.markPeopleWriteReturned(operationID: operation.id)
            let written = try PhotosAdapter.read(id: id)
            try db.confirmPeopleWrite(operationID: operation.id, description: written.description, keywords: written.keywords)
            guard let verified = try db.peopleOperation(id: operation.id) else { throw StoreError.invalidTransition }
            try db.beginPeopleUndo(operationID: operation.id)
            _ = try PhotosAdapter.undoPeople(id: id, operation: verified)
            let after = try PhotosAdapter.read(id: id)
            try db.confirmPeopleUndo(operationID: operation.id, description: after.description, keywords: after.keywords)
            guard before.description == after.description, before.keywords == after.keywords else { throw StoreError.invalidTransition }
            print("人物写入与撤销链路通过，原说明和关键词保持一致。")
        } catch {
            fputs("测试结果不确定，记录保留于 \(dbURL.path)，请勿自动重试。\n", stderr)
            exit(1)
        }
    }
}
