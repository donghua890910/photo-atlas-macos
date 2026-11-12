import Foundation
import AtlasCore

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    fputs("提供一个或多个旧版数据库快照路径。仅用于只读导入验证。\n", stderr)
    exit(2)
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtlasAudit-" + UUID().uuidString, isDirectory: true)
do {
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try Store(url: temp.appendingPathComponent("audit.sqlite"))
    for path in arguments {
        let url = URL(fileURLWithPath: path)
        let staged: URL
        if url.pathExtension == "jsonl" {
            staged = url
        } else {
            staged = temp.appendingPathComponent(url.lastPathComponent)
            try LegacySnapshot.copyDatabase(source: url, destination: staged)
        }
        let count = url.pathExtension == "jsonl" ? try store.importLegacyResults(from: staged) : try store.importLegacy(from: staged)
        print("\(url.lastPathComponent): \(count) 条历史记录，均待核验")
    }
} catch {
    fputs("历史数据导入验证失败：\(error)\n", stderr)
    exit(1)
}

