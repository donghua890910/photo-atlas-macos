import Foundation
import AtlasCore

@main
struct WriteUndoProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 || (args.count == 3 && ["--queued-noop", "--automatic-noop"].contains(args[2])) else { fputs("需要私有快照文件路径。\n", stderr); exit(2) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = snapshot["asset_id"] as? String else { throw StoreError.invalidInput }
            let before = try PhotosAdapter.read(id: id)
            guard !before.description.isEmpty else { throw StoreError.invalidInput }
            if args.count == 3 {
                guard !before.keywords.isEmpty else { throw StoreError.invalidInput }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtlasQueueProbe-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                let url = folder.appendingPathComponent("atlas.sqlite")
                let store = try Store(url: url)
                try store.cache(assetID: id, description: before.description, keywords: before.keywords, sensitive: false)
                let automatic = args[2] == "--automatic-noop"
                if automatic {
                    try store.enqueueAIAssets([id], priority: 10, automaticallyWrite: true)
                    try store.setScanEnabled(true)
                } else {
                    try store.approveWrite(assetID: id, description: before.description, keywords: before.keywords)
                }
                let engine = try WriteEngine(url: url, read: { identifier in
                    try await Task.detached { try PhotosAdapter.read(id: identifier) }.value
                }, write: { identifier, original, description, words in
                    _ = try await Task.detached { try PhotosAdapter.write(id: identifier, before: original, description: description, keywords: words) }.value
                })
                if automatic {
                    let prepared = await engine.runOne()
                    guard prepared == .completed, try store.scanProgress().pendingWrites == 1,
                          try store.writeReceipt(assetID: id) == nil else { throw StoreError.invalidTransition }
                }
                let outcome = await engine.runOne()
                let after = try PhotosAdapter.read(id: id)
                guard outcome == .completed, before.description == after.description, before.keywords == after.keywords,
                      try store.writeReceipt(assetID: id)?.addedKeywords == [], try store.scanProgress().outstanding == 0 else { throw StoreError.invalidTransition }
                print(automatic ? "真实照片的自动排队、写入与回读测试通过，原说明和关键词一致。" : "真实照片的后台队列无变更测试通过，原说明与关键词一致。")
                return
            }
            let marker = "PhotoAtlas-验证-" + UUID().uuidString
            let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("backups/write-probes", isDirectory: true)
            let dbURL = folder.appendingPathComponent("undo-" + UUID().uuidString + ".sqlite")
            let db = try Store(url: dbURL)
            try db.cache(assetID: id, description: "验证", keywords: [marker], sensitive: false)
            try db.saveSnapshot(assetID: id, description: before.description, keywords: before.keywords)
            try db.beginWrite(assetID: id)
            _ = try PhotosAdapter.write(id: id, before: before, description: "验证", keywords: [marker])
            let written = try PhotosAdapter.read(id: id)
            try db.confirmWrite(assetID: id, description: written.description, keywords: written.keywords)
            guard let receipt = try db.writeReceipt(assetID: id) else { throw StoreError.invalidTransition }
            try db.beginUndo(assetID: id)
            _ = try PhotosAdapter.undo(id: id, receipt: receipt)
            let after = try PhotosAdapter.read(id: id)
            try db.finishUndo(assetID: id, description: after.description, keywords: after.keywords)
            guard before.description == after.description, before.keywords == after.keywords else { throw StoreError.invalidTransition }
            print("临时关键词写入、回读、撤销及再次回读成功；原说明与关键词完整保留。")
        } catch {
            fputs("测试未完成：请检查 backups/write-probes 中的记录，并核验照片；不会自动重试。\n", stderr)
            exit(1)
        }
    }
}
