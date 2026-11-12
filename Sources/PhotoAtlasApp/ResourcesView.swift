import SwiftUI
import AtlasCore

struct ResourcesView: View {
    @State private var snapshot: ResourceSnapshot?
    @State private var sampledAt: Date?
    @State private var sampler = ResourceSampler()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("系统监控").font(.largeTitle.bold())
                Text("当前显示管理中心进程自身的资源使用，不包含独立后台、Ollama 或照片应用。")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    StatCard(title: "应用 CPU", value: snapshot?.appCPUPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "采样中", symbol: "cpu")
                    StatCard(title: "应用峰值内存", value: bytes(snapshot?.appPeakMemoryBytes), symbol: "memorychip")
                }
                Text("CPU 按两次采样之间的实际处理器时间计算，单核满载为 100%。内存数值是本次进程运行以来的峰值，并非当前占用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    StatCard(title: "Mac 物理内存", value: bytes(snapshot?.physicalMemoryBytes), symbol: "desktopcomputer")
                    StatCard(title: "系统温度状态", value: snapshot?.thermal ?? "—", symbol: "thermometer.medium")
                }
                HStack(spacing: 14) {
                    StatCard(title: "可用磁盘", value: bytes(snapshot?.disk?.available), symbol: "externaldrive")
                    StatCard(title: "磁盘总容量", value: bytes(snapshot?.disk?.total), symbol: "internaldrive")
                }
                if let disk = snapshot?.disk, disk.available < DiskSpace.minimumAvailable {
                    Label("可用空间不足 1 GB，后台不会领取新任务。释放空间后可继续。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("人物索引助手复制图库数据库前还会检查额外空间需求。磁盘空间可能被其他程序同时使用，保护机制不能保证运行期间永不耗尽空间。")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("尚不可用的指标") {
                    Text("GPU 实时利用率、系统整体 CPU、内存压力、交换内存和历史趋势尚未接入，不显示估算值。")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let sampledAt { Text("最近采样：\(sampledAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }.padding(32)
        }
        .navigationTitle("系统监控")
        .task {
            let directory = ScanController.shared.database.deletingLastPathComponent()
            while !Task.isCancelled {
                let value = await sampler.sample(directory: directory)
                guard !Task.isCancelled else { break }
                snapshot = value
                sampledAt = Date()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value, value <= UInt64(Int64.max) else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
