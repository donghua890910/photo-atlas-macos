import Foundation
import AtlasCore

@main
struct PipelineProbe {
    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let databaseURL = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let db = try Store(url: databaseURL)
            try db.enqueue(assetID: "synthetic-test", kind: .ai, priority: 1)
            let engine = try ProcessingEngine(url: databaseURL, preview: { _ in try Data(contentsOf: imageURL) }, analyze: { try await Ollama.infer(image: $0) })
            let started = Date()
            guard await engine.runOne() == .completed,
                  let result = try db.result(assetID: "synthetic-test"),
                  try db.outstanding(kind: .ai) == 0 else { throw StoreError.invalidTransition }
            print("隔离队列完成：结果已保存，关键词 \(result.keywords.count) 个，用时 \(Int(Date().timeIntervalSince(started))) 秒。")
        } catch {
            fputs("隔离队列测试未完成。\n", stderr)
            exit(1)
        }
    }
}
