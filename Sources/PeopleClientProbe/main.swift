import Foundation
import AtlasCore

@main
struct PeopleClientProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 || (args.count == 3 && args[2] == "--index") else { exit(2) }
        do {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let json = try JSONSerialization.jsonObject(with: input) as? [String: Any], let id = json["asset_id"] as? String else { throw StoreError.invalidInput }
            let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI-Photo-Manager/.venv/bin/python")
            let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tools/people_index.py")
            let client = PeopleClient(executable: python, script: script)
            if args.count == 3 {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtlasIndexProbe-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let database = directory.appendingPathComponent("atlas.sqlite")
                let store = try Store(url: database)
                try store.enqueueIndexAssets([id])
                let engine = try IndexingEngine(url: database, lookup: { identifier in try await client.candidates(for: identifier) })
                let outcome = await engine.runOne()
                await client.stop()
                guard outcome == .completed, try store.scanProgress().indexed == 1,
                      try store.result(assetID: id) == nil, try store.statistics().verifiedWrites == 0,
                      let location = try store.locationCandidates(assetID: id) else { throw StoreError.invalidTransition }
                print("真实本地索引任务保存成功；地点状态：\(location.status.rawValue)，地点词数：\(location.keywords.count)。未执行 AI 或照片写入。")
                return
            }
            let first = try await client.names(for: id)
            let second = try await client.names(for: id)
            await client.stop()
            guard first == second else { throw StoreError.invalidTransition }
            print("人物索引客户端连续查询成功；两次结果一致。")
        } catch {
            fputs("人物索引客户端验证未完成。\n", stderr)
            exit(1)
        }
    }
}
