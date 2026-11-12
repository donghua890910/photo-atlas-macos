import Foundation
import AtlasCore

guard CommandLine.arguments.count == 3 else { exit(2) }
do {
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let support = URL(fileURLWithPath: CommandLine.arguments[2])
    let result = try LegacyMigration.run(source: source, support: support)
    switch result {
    case .imported(let files, let records): print("已在隔离目录导入 \(files) 个来源、\(records) 条待核验记录。")
    case .alreadyImported: print("历史记录已导入。")
    case .noLegacy: print("未发现旧数据。")
    }
} catch {
    fputs("旧数据迁移未完成；原文件未更改。\n", stderr)
    exit(1)
}
