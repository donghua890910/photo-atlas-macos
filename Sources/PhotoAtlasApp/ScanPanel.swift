import SwiftUI
import Photos
import AtlasCore

struct ScanPanel: View {
    @ObservedObject private var scan = ScanController.shared
    private var progress: ScanProgress? { scan.progress }
    private var message: String { scan.message }
    @State private var preparing = false
    @State private var wholeLibrary = false

    private var database: URL { scan.database }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("智能扫描").font(.largeTitle.bold())
                Text(scan.status).font(.headline)
                Text(message).foregroundStyle(.secondary)
                HStack {
                    StatCard(title: "等待识别", value: String(progress?.pending ?? 0), symbol: "tray")
                    StatCard(title: "处理中", value: String(progress?.running ?? 0), symbol: "sparkles")
                    StatCard(title: "已生成", value: String(progress?.done ?? 0), symbol: "checkmark.circle")
                }
                Text("无法读取预览：\(progress?.skipped ?? 0) 张。iCloud 照片会按需获取预览。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("人物与地点已读取：\(progress?.indexed ?? 0) · 等待读取：\((progress?.pendingIndex ?? 0) + (progress?.runningIndex ?? 0))")
                    .font(.callout).foregroundStyle(.secondary)
                Text("待写入：\(progress?.pendingWrites ?? 0) · 正在写入：\(progress?.runningWrites ?? 0) · 待核验：\(progress?.uncertainWrites ?? 0)")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("扫描全部照片", isOn: $wholeLibrary).disabled(preparing || progress?.enabled == true)
                Text(wholeLibrary ? "从新到旧补齐 AI 与元数据，已有 AI 结果会跳过推理。" : "先处理最近 10 张照片，已有 AI 结果会跳过推理。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(preparing ? "正在建立队列…" : "开始扫描并写入") { Task { await start() } }
                        .buttonStyle(.borderedProminent).disabled(preparing || scan.preparingAccess || progress?.enabled == true)
                    Button("暂停") { scan.pause() }.disabled(progress?.enabled != true)
                    Button("继续已有队列") { scan.resume() }.disabled(preparing || !scan.canResume)
                }
                Text("暂停会在当前照片识别并保存后生效。后台进程独立运行，关闭主窗口后仍可继续；退出或重启后，可点击继续已有队列恢复。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("AI 说明和关键词会自动写入并回读核验，包含 AI 标记为敏感的结果。手动禁止写入的照片会跳过，已有说明会保留。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(32)
        }
        .navigationTitle("智能扫描")
        .task { await scan.monitor() }
    }

    @MainActor private func start() async {
        guard !AppEnvironment.isUITest else { scan.report("独立界面测试不会扫描真实照片。"); return }
        guard !preparing else { return }
        guard await scan.prepareAccess() else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { scan.report("请先在总览中授权照片访问。"); return }
        preparing = true
        defer { preparing = false }
        let url = database, all = wholeLibrary
        do {
            let added = try await Task.detached(priority: .utility) {
                let db = try Store(url: url)
                try DiskSpace.read(at: url.deletingLastPathComponent()).requireCapacity()
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let assets = PHAsset.fetchAssets(with: .image, options: options)
                var batch: [String] = [], added = 0, selected = 0
                for index in 0..<assets.count {
                    try Task.checkCancellation()
                    let id = assets.object(at: index).localIdentifier
                    batch.append(id)
                    selected += 1
                    if batch.count == 500 {
                        try DiskSpace.read(at: url.deletingLastPathComponent()).requireCapacity()
                        added += try db.enqueueAIAssets(batch, priority: 10, automaticallyWrite: true)
                        added += try db.enqueueIndexAssets(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                    if !all && selected == 10 { break }
                }
                added += try db.enqueueAIAssets(batch, priority: 10, automaticallyWrite: true)
                added += try db.enqueueIndexAssets(batch)
                return added
            }.value
            scan.report("已新增 \(added) 项任务，已有队列和结果保留。")
            scan.resume()
        } catch ResourceError.diskSpaceLow { scan.report("可用空间不足 1 GB，停止建立队列。已保存的任务保留，请释放空间后继续。") }
        catch { scan.report("建立队列未完成，已保存的任务保留，可以重试。") }
    }

}
