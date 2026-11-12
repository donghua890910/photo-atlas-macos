import SwiftUI
import AtlasCore

struct RecordsView: View {
    @State private var query = ""
    @State private var filter: RecordFilter = .all
    @State private var offset = 0
    @State private var rows: [RecordSummary] = []
    @State private var error: String?
    @State private var refreshID = 0

    private var requestKey: String { "\(filter.rawValue):\(offset):\(refreshID):\(query)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("显示", selection: $filter) {
                        ForEach(RecordFilter.allCases, id: \.self) { value in Text(title(value)).tag(value) }
                    }.frame(maxWidth: 260)
                    Spacer()
                    Button("刷新") { refreshID += 1 }
                }.padding()
                if let error { Text(error).font(.callout).foregroundStyle(.orange).padding() }
                List {
                    ForEach(Array(rows.prefix(50))) { record in
                        NavigationLink(value: record.id) {
                            GeometryReader { geometry in
                                HStack(alignment: .top, spacing: 16) {
                                    Thumbnail(id: record.id)
                                        .frame(width: 100, height: 110)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(record.description ?? "人物与地点候选，尚无 AI 结果")
                                            .lineLimit(2)
                                        Text((record.keywords + record.people + record.places).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(record.sensitive ? "敏感 · \(status(record))" : status(record))
                                            .font(.caption).foregroundStyle(record.sensitive ? .orange : .secondary).lineLimit(1)
                                        Text(record.updatedAt).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(width: max(0, geometry.size.width - 116), alignment: .leading)
                                }
                            }
                            .frame(height: 120)
                            .padding(.vertical, 5)
                        }
                    }
                    if rows.isEmpty && error == nil {
                        Text(query.isEmpty ? "暂无符合条件的处理记录。" : "没有找到匹配记录。")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("第 \(offset / 50 + 1) 页").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("上一页") { offset = max(0, offset - 50) }.disabled(offset == 0)
                    Button("下一页") { offset += 50 }.disabled(rows.count <= 50)
                }.padding()
            }
            .navigationTitle("处理记录")
            .searchable(text: $query, prompt: "搜索说明、关键词、人物、地点或资源编号")
            .navigationDestination(for: String.self) { id in PhotoBrowser(initialAssetID: id) }
            .onChange(of: query) { _ in offset = 0 }
            .onChange(of: filter) { _ in offset = 0 }
            .task(id: requestKey) {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                await load()
            }
        }
    }

    @MainActor private func load() async {
        let search = query, selected = filter, start = offset
        let database = ScanController.shared.database
        do {
            let values = try await Task.detached(priority: .utility) {
                try Store(url: database).records(query: search, filter: selected, limit: 51, offset: start)
            }.value
            guard !Task.isCancelled, query == search, filter == selected, offset == start else { return }
            rows = values
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            self.error = "无法读取处理记录，请检查磁盘和本机数据。"
        }
    }

    private func title(_ filter: RecordFilter) -> String {
        switch filter {
        case .all: "全部记录"
        case .pending: "等待审核"
        case .verified: "写入已核验"
        case .needsVerification: "写入待核验"
        case .sensitive: "敏感照片"
        case .metadata: "人物与地点"
        }
    }

    private func status(_ record: RecordSummary) -> String {
        if record.metadataNeedsVerification { return "人物或地点写入、撤销需要核验" }
        if record.receiptStatus == "undone" { return "已撤销本次新增关键词，说明保留" }
        if record.receiptStatus == "undoing" || record.receiptStatus == "needs_review" { return "AI 关键词撤销需要核验" }
        switch record.state {
        case .pending: return "AI 已生成，等待审核或写入"
        case .writing: return "写入处理中，请等待或核验"
        case .needsVerification: return "写入需要核验"
        case .verified: return "AI 写入已回读核验"
        case .blocked: return "禁止写入"
        case nil: return "仅有本地元数据候选，未执行 AI 写入"
        }
    }
}
