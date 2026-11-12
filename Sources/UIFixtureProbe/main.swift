import Foundation
import AtlasCore

@main struct UIFixtureProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        do {
            let root = try UITestStorage.validatedDirectory(CommandLine.arguments[1])
            let database = root.appendingPathComponent("atlas.sqlite")
            guard !FileManager.default.fileExists(atPath: database.path) else { throw StoreError.invalidInput }
            let store = try Store(url: database)
            let first = "00000000-0000-4000-8000-000000000001/L0/001"
            let second = "00000000-0000-4000-8000-000000000002/L0/001"
            let third = "00000000-0000-4000-8000-000000000003/L0/001"
            try store.cache(assetID: first, description: "模拟队列照片，等待审核后的后台写入。", keywords: ["模拟标签"], sensitive: false, origin: "ui_fixture")
            try store.approveWrite(assetID: first, description: "模拟原说明", keywords: ["模拟原词"])
            try store.recordPersonCandidates(assetID: first, names: ["模拟人物"])
            try store.recordLocationCandidates(assetID: first, value: LocationCandidates(status: .localAddress, keywords: ["模拟城市"]))
            try store.cache(assetID: second, description: "模拟待审核照片。", keywords: ["模拟风景"], sensitive: false, origin: "ui_fixture")
            try store.cache(assetID: third, description: "模拟敏感文档。", keywords: ["文件"], sensitive: true, origin: "ui_fixture")
            print("已创建三个模拟记录和一个未执行的写入任务。")
        } catch { fputs("隔离界面测试数据创建失败。\n", stderr); exit(1) }
    }
}
