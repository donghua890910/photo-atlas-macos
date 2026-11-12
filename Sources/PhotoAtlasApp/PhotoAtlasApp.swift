import SwiftUI
import Photos
import AppKit
import Darwin
import AtlasCore

struct PhotoAtlasApp: App {
    var body: some Scene {
        WindowGroup("Photo Atlas", id: "main") {
            Dashboard()
                .frame(minWidth: 760, minHeight: 520)
                .safeAreaInset(edge: .bottom) {
                    if AppEnvironment.isUITest {
                        Text("独立界面测试 · 模拟记录 · 不访问照片和正式数据").font(.caption).padding(8).frame(maxWidth: .infinity).background(.orange.opacity(0.15))
                    }
                }
        }
        .defaultSize(width: 1020, height: 680)
        MenuBarExtra("Photo Atlas", systemImage: "photo.stack") {
            ScanMenu()
        }.menuBarExtraStyle(.window)
    }
}

struct Dashboard: View {
    @ObservedObject private var scan = ScanController.shared
    @State private var page = "overview"
    @State private var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var imageCount: Int?
    @State private var videoCount: Int?
    @State private var isLoading = false
    @State private var ollamaStatus = "尚未检测"
    @State private var backgroundStatus = "尚未检测"
    @State private var legacyStatus = "尚未检查"
    @State private var modelAvailable = false
    @State private var statistics: DashboardStats?
    @State private var mappingStatus: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("总览", systemImage: "square.grid.2x2")
                    .tag("overview")
                Label("照片浏览", systemImage: "photo.on.rectangle")
                    .tag("photos")
                Label("智能扫描", systemImage: "sparkles")
                    .tag("scan")
                Label("处理记录", systemImage: "clock.arrow.circlepath")
                    .tag("records")
                Label("系统监控", systemImage: "waveform.path.ecg")
                    .tag("resources")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 9) {
                    Image(systemName: "photo.stack.fill").foregroundStyle(.blue)
                    Text("Photo Atlas").font(.headline)
                    Spacer()
                }.padding(16)
            }
        } detail: {
            if page == "photos" {
                PhotoBrowser()
            } else if page == "scan" {
                ScanPanel()
            } else if page == "records" {
                RecordsView()
            } else if page == "resources" {
                ResourcesView()
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AtlasHero(status: scan.status, active: scan.workerRunning)
                    HStack(spacing: 14) {
                        StatCard(title: "照片", value: imageCount.map { $0.formatted() } ?? "—", symbol: "photo")
                        StatCard(title: "视频", value: videoCount.map { $0.formatted() } ?? "—", symbol: "video")
                        StatCard(title: "整理状态", value: scan.status, symbol: "pause.circle")
                    }
                    HStack(spacing: 14) {
                        StatCard(title: "AI 已生成", value: statistics.map { $0.aiCached.formatted() } ?? "—", symbol: "sparkles")
                        StatCard(title: "写入已验证", value: statistics.map { $0.verifiedWrites.formatted() } ?? "—", symbol: "checkmark.circle")
                        StatCard(title: "待写入", value: statistics.map { $0.pendingWrites.formatted() } ?? "—", symbol: "tray")
                    }
                    if let stats = statistics, stats.needsVerification > 0 || stats.sensitive > 0 {
                        Text("敏感结果 \(stats.sensitive) · 待核验写入 \(stats.needsVerification)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("照片图库", systemImage: "photo.on.rectangle.angled")
                                .font(.headline)
                            Text(authorizationText).foregroundStyle(.secondary)
                            HStack {
                                Button(authorization == .notDetermined ? "授权访问照片" : "检查图库") {
                                    Task { await checkLibrary(request: authorization == .notDetermined); await checkRequestedAsset(); await checkBackground() }
                                }
                                .disabled(AppEnvironment.isUITest || isLoading || authorization == .denied || authorization == .restricted)
                                if authorization == .denied || authorization == .restricted {
                                    Button("打开隐私设置") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                                if isLoading { ProgressView().controlSize(.small) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if let mappingStatus {
                        Label(mappingStatus, systemImage: "checkmark.shield").foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("本地 AI 模型", systemImage: "sparkles").font(.headline)
                            Text(ollamaStatus).foregroundStyle(.secondary)
                            Button("检测 Ollama") { Task { await checkOllama() } }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("旧版进度", systemImage: "archivebox") .font(.headline)
                            Text(legacyStatus).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("后台进程", systemImage: "gearshape.2").font(.headline)
                            Text(backgroundStatus).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Label("智能扫描会自动写入符合条件的 AI 结果，并核验写入内容。", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                }
                .padding(32)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            }
        }
        .task { refreshStatistics(); await migrateLegacy(); if !AppEnvironment.isUITest { _ = await scan.prepareAccess() }; await checkLibrary(request: false); await checkOllama(); await checkRequestedAsset(); await checkBackground() }
        .task { await scan.monitor() }
        .onChange(of: page) { value in if value == "overview" { refreshStatistics() } }
    }

    @MainActor private func refreshStatistics() {
        do {
            statistics = try Store(url: AppEnvironment.database).statistics()
        } catch { statistics = nil }
    }

    private var authorizationText: String {
        switch authorization {
        case .authorized: "已获得照片图库访问权限。读取数量不会下载 iCloud 原片。"
        case .limited: "当前只允许访问部分照片；统计不代表整个图库。"
        case .denied: "照片访问被拒绝。请在系统设置中允许访问。"
        case .restricted: "此 Mac 的限制阻止了照片访问。"
        case .notDetermined: "请授权访问，以读取图库统计。"
        @unknown default: "无法确定照片访问状态。"
        }
    }

    @MainActor private func checkLibrary(request: Bool) async {
        guard !AppEnvironment.isUITest else { imageCount = nil; videoCount = nil; return }
        isLoading = true
        defer { isLoading = false }
        if request { authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        else { authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        guard authorization == .authorized || authorization == .limited else {
            imageCount = nil; videoCount = nil; return
        }
        let counts = await Task.detached(priority: .utility) {
            (PHAsset.fetchAssets(with: .image, options: nil).count,
             PHAsset.fetchAssets(with: .video, options: nil).count)
        }.value
        imageCount = counts.0
        videoCount = counts.1
    }

    @MainActor private func checkRequestedAsset() async {
        guard !AppEnvironment.isUITest else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--verify-asset"), args.indices.contains(index + 1) else { return }
        guard authorization == .authorized || authorization == .limited else {
            mappingStatus = "资源映射验证需要照片访问权限"
            return
        }
        let identifier = args[index + 1]
        let found = await Task.detached(priority: .utility) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            return assets.count == 1 && assets.firstObject?.localIdentifier == identifier
        }.value
        mappingStatus = found ? "选中照片的 PhotoKit 与 Photos 标识一致" : "未能在 PhotoKit 中验证选中照片标识"
    }

    @MainActor private func migrateLegacy() async {
        guard !AppEnvironment.isUITest else { legacyStatus = "独立界面测试，不读取旧项目。"; return }
        legacyStatus = "正在安全备份并读取旧版记录…"
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI-Photo-Manager", isDirectory: true)
        let support = AppEnvironment.support
        let outcome = await Task.detached(priority: .utility) {
            try? LegacyMigration.run(source: source, support: support)
        }.value
        switch outcome {
        case .noLegacy: legacyStatus = "未发现旧版进度。"
        case .alreadyImported: legacyStatus = "旧版记录已保留为待核验数据。"
        case .imported(let files, let records): legacyStatus = "已备份 \(files) 个来源，保留 \(records.formatted()) 条待核验记录。"
        case nil: legacyStatus = "旧版记录迁移未完成；原文件未更改。"
        }
    }

    @MainActor private func checkBackground() async {
        guard !AppEnvironment.isUITest else { backgroundStatus = "独立界面测试，不启动真实后台。"; return }
        guard authorization == .authorized || authorization == .limited else {
            backgroundStatus = "需要照片访问权限后才能检查。"
            return
        }
        guard let executable = Bundle.main.executableURL else {
            backgroundStatus = "无法定位后台程序。"
            return
        }
        backgroundStatus = "正在检查…"
        let status = await Task.detached(priority: .utility) { () -> Int32 in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtlasHealth-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let child = Process()
                child.executableURL = executable
                child.arguments = ["--worker", folder.appendingPathComponent("probe.sqlite").path]
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                defer {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
                }
                let deadline = Date().addingTimeInterval(15)
                while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                if child.isRunning {
                    child.terminate()
                    let grace = Date().addingTimeInterval(1)
                    while child.isRunning && Date() < grace { try await Task.sleep(nanoseconds: 50_000_000) }
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    child.waitUntilExit()
                    return -1
                }
                child.waitUntilExit()
                return child.terminationStatus
            } catch { return -1 }
        }.value
        switch status {
        case 0: backgroundStatus = "进程和照片权限检查通过，可进入智能扫描。"
        case 2: backgroundStatus = "后台进程未获得照片权限，自动扫描已关闭。"
        default: backgroundStatus = "后台进程检查未完成，自动扫描已关闭。"
        }
    }

    @MainActor private func checkOllama() async {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                throw URLError(.badServerResponse)
            }
            modelAvailable = models.contains { ($0["name"] as? String) == "qwen3-vl:4b-instruct" }
            ollamaStatus = modelAvailable ? "Ollama 已连接 · qwen3-vl:4b-instruct 已安装" : "Ollama 已连接，但未找到 qwen3-vl:4b-instruct"
        } catch {
            modelAvailable = false
            ollamaStatus = "无法连接本机 Ollama，请确认服务已启动。"
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
    }
}

private struct AtlasHero: View {
    let status: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PHOTO ATLAS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2.5).foregroundStyle(.white.opacity(0.7))
                Text("让每一张照片都有迹可寻")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Label(status, systemImage: active ? "sparkles" : "circle.dotted")
                    .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.white.opacity(glow ? 0.95 : 0.65))
                .scaleEffect(glow ? 1.06 : 1)
                .accessibilityHidden(true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 166, alignment: .leading)
        .background(LinearGradient(colors: [.indigo, .blue, .teal.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.2)))
        .shadow(color: .blue.opacity(0.18), radius: 20, y: 10)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
