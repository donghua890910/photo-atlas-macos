import SwiftUI
import AtlasCore
import Photos

@MainActor final class ScanController: ObservableObject {
    static let shared = ScanController()
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var message = "开始扫描后，符合条件的 AI 结果将自动写入照片。"
    @Published private(set) var workerRunning = false
    @Published private(set) var recovering = false
    @Published private(set) var waitingForOperation = false
    @Published private(set) var noRecentProgress = false
    @Published private(set) var preparingAccess = false
    @Published private(set) var accessReady = false
    private var child: Process?
    private var lastProgressKey: String?
    private var lastProgressTime = Date()
    let database = AppEnvironment.database

    var canResume: Bool {
        guard let progress else { return false }
        return !workerRunning && (progress.outstanding > 0 || progress.uncertainWrites > 0)
    }

    var status: String {
        if recovering { return "正在恢复后台" }
        if waitingForOperation { return "等待当前操作，超时将自动恢复" }
        if noRecentProgress { return "较长时间没有新结果，后台正在重试" }
        if workerRunning { return progress?.enabled == true ? "正在扫描" : "正在保存后暂停" }
        if (progress?.uncertainWrites ?? 0) > 0 { return "有写入需要核验" }
        if progress?.outstanding == 0 { return "队列空闲" }
        return "已暂停，可继续"
    }

    func refresh() {
        do {
            let store = try Store(url: database)
            progress = try store.scanProgress()
            let directory = database.deletingLastPathComponent()
            let worker = WorkerLease.isHeld(directory: directory)
            let supervisor = WorkerLease.isHeld(directory: directory, name: WorkerSupervisor.leaseName)
            workerRunning = worker || supervisor
            recovering = supervisor && !worker && progress?.enabled == true
            let modified = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("worker-heartbeat").path)[.modificationDate] as? Date
            waitingForOperation = supervisor && worker && progress?.enabled == true && (modified.map { Date().timeIntervalSince($0) > 300 } ?? false)
            if let progress, progress.enabled && workerRunning {
                let verified = try store.statistics().verifiedWrites
                let key = "\(progress.done):\(progress.indexed):\(verified)"
                if key != lastProgressKey { lastProgressKey = key; lastProgressTime = Date() }
                noRecentProgress = Date().timeIntervalSince(lastProgressTime) > 600
            } else {
                lastProgressKey = nil
                lastProgressTime = Date()
                noRecentProgress = false
            }
        } catch { message = "无法读取任务记录，请检查可用磁盘空间。" }
    }

    func monitor() async {
        while !Task.isCancelled {
            refresh()
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
        }
    }

    func prepareAccess() async -> Bool {
        guard !AppEnvironment.isUITest else { return false }
        guard !preparingAccess else { return false }
        preparingAccess = true
        defer { preparingAccess = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            accessReady = false
            message = "请在系统设置中允许 Photo Atlas 访问照片。"
            return false
        }
        do {
            try await Task.detached(priority: .utility) {
                guard let asset = PHAsset.fetchAssets(with: .image, options: nil).firstObject else { return }
                _ = try PhotosAdapter.read(id: asset.localIdentifier)
            }.value
            accessReady = true
            message = "照片访问和自动化检查已通过。"
            return true
        } catch {
            accessReady = false
            message = "请允许 Photo Atlas 控制照片应用，然后重试。"
            return false
        }
    }

    func resume() {
        Task {
            guard await prepareAccess() else { return }
            startWorker()
        }
    }

    func restoreIfNeeded() {
        guard !AppEnvironment.isUITest, (try? Store(url: database).scanEnabled()) == true else { return }
        startWorker()
    }

    private func startWorker() {
        guard !AppEnvironment.isUITest else { message = "独立界面测试不会启动真实后台。"; return }
        do {
            let db = try Store(url: database)
            try DiskSpace.read(at: database.deletingLastPathComponent()).requireCapacity()
            let executable = AppEnvironment.workerExecutable
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw StoreError.invalidInput }
            try db.setScanEnabled(true)
            let directory = database.deletingLastPathComponent()
            if WorkerLease.isHeld(directory: directory) || WorkerLease.isHeld(directory: directory, name: WorkerSupervisor.leaseName) || child?.isRunning == true {
                message = "后台正在处理队列。"
                refresh()
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--supervisor", database.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in self?.finished(status: status) }
            }
            do { try process.run() } catch { try db.setScanEnabled(false); throw error }
            child = process
            message = "后台已启动，正在检查权限并处理队列。"
            refresh()
        } catch ResourceError.diskSpaceLow { message = "可用空间不足 1 GB，后台已停止。请释放空间后继续，任务记录已保留。" }
        catch { message = "无法启动后台，任务记录已保留。" }
    }

    func pause() {
        do {
            try Store(url: database).setScanEnabled(false)
            message = "已请求暂停，当前照片保存后停止。"
            refresh()
        } catch { message = "暂停请求未保存，请重试。" }
    }

    func report(_ value: String) { message = value }

    private func finished(status: Int32) {
        child = nil
        do {
            let db = try Store(url: database)
            refresh()
            let enabled = try db.scanEnabled()
            if status != 4 && enabled {
                message = "后台中断，正在自动恢复。"
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, (try? Store(url: self.database).scanEnabled()) == true else { return }
                    self.startWorker()
                }
                return
            }
            switch status {
            case 0:
                if (progress?.uncertainWrites ?? 0) > 0 {
                    message = "后台已停止，有写入需要核验，请在照片浏览中检查；不会自动重试。"
                } else {
                    message = progress?.outstanding == 0 ? "本轮队列已处理完成。可在处理记录查看结果。" : "后台已暂停，识别结果和队列已保留。"
                }
            case 2: message = "后台进程无法访问照片。队列已保留，请检查系统照片权限。"
            case 4: message = "已有后台进程正在处理队列。"
            case 5: message = "可用空间不足 1 GB，后台已停止。任务记录已保留，请释放空间后继续。"
            case 6: message = "写入流程已暂停。请检查照片访问和自动化权限，或查看待核验记录。其余任务已保留。"
            default: message = "后台已停止。结果和队列已保留，继续时会恢复中断的识别和索引任务。"
            }
        } catch { message = "后台已停止，无法读取任务记录。" }
    }
}

struct ScanMenu: View {
    @ObservedObject private var scan = ScanController.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photo Atlas · \(scan.status)").font(.headline)
            Text("已生成 \(scan.progress?.done ?? 0) · 待识别 \(scan.progress?.pending ?? 0)")
            Text(scan.message).font(.caption)
            Divider()
            Button("暂停扫描") { scan.pause() }.disabled(!scan.workerRunning)
            Button("继续队列") { scan.resume() }
                .disabled(!scan.canResume)
            Button("打开管理中心") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }.padding(16).frame(width: 310)
        .task { await scan.monitor() }
    }
}
