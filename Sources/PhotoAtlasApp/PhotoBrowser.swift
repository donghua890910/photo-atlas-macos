import SwiftUI
import Photos
import AppKit
import AtlasCore

struct PhotoBrowser: View {
    var initialAssetID: String? = nil
    @State private var ids: [String] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var selection: String?
    @State private var result: CachedResult?
    @State private var legacy: LegacySuggestion?
    @State private var receipt: WriteReceipt?
    @State private var writeQueued = false
    @State private var manualPrivacy = false
    @State private var showPrivacyConfirmation = false
    @State private var personNames: [String]?
    @State private var location: LocationCandidates?
    @State private var peopleOperation: PeopleWriteOperation?
    @State private var locationOperation: PeopleWriteOperation?
    @State private var peopleClient: PeopleClient?
    @State private var showPeopleConfirmation = false
    @State private var showPeopleUndoConfirmation = false
    @State private var showLocationConfirmation = false
    @State private var showLocationUndoConfirmation = false
    @State private var message = "选择照片后，可以使用本地 AI 生成待审核结果。"
    @State private var working = false
    @State private var showWriteConfirmation = false
    @State private var showUndoConfirmation = false
    @State private var showEditor = false
    @State private var draftDescription = ""
    @State private var draftKeywords = ""
    @State private var editError = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
            HStack {
                Text(total == 0 ? "暂无照片" : "第 \(offset + 1)–\(offset + ids.count) 张，共 \(total.formatted()) 张")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("较新") { offset = max(0, offset - 48); loadRecent() }.disabled(offset == 0 || working)
                Button("较旧") { offset += 48; loadRecent() }.disabled(offset + ids.count >= total || working)
            }.padding([.horizontal, .top], 20)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        Button {
                            selection = id
                            loadCached(id)
                        } label: {
                            Thumbnail(id: id)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == id ? Color.accentColor : .clear, lineWidth: 3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择照片")
                    }
                }.padding(20)
                if ids.isEmpty {
                    Text("没有可显示的照片。请先在总览中授权照片访问。").foregroundStyle(.secondary).padding()
                }
            }
            }.frame(minWidth: 380)
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI 人工审核").font(.title2.bold())
                if let selection { Thumbnail(id: selection, fit: true).id(selection).frame(maxWidth: 320).accessibilityLabel("当前审核照片预览") }
                Text(message).foregroundStyle(.secondary)
                if let result {
                    if result.origin.hasPrefix("legacy:") {
                        Label("来自旧版记录，内容及照片匹配需要审核", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("照片说明").font(.headline)
                    Text(result.description).textSelection(.enabled)
                    if let category = result.category, !category.isEmpty {
                        Text("分类：\(category)").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("关键词").font(.headline)
                    Text(result.keywords.joined(separator: " · ")).textSelection(.enabled)
                    if result.sensitive {
                        Label(manualPrivacy ? "已手动禁止写入" : "可能包含敏感内容", systemImage: "lock.shield")
                            .foregroundStyle(.orange)
                    }
                }
                if result == nil, let legacy {
                    Label("发现可能匹配的旧版结果", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text("旧记录按资源编号匹配，请确认照片和内容；尚未认定为写入成功。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(legacy.result.description).textSelection(.enabled)
                    Text(legacy.result.keywords.joined(separator: " · ")).font(.callout).textSelection(.enabled)
                    if legacy.result.sensitive { Label("可能包含敏感内容", systemImage: "lock.shield").foregroundStyle(.orange) }
                    Button("采用旧结果并审核") { useLegacy(legacy) }.disabled(working)
                }
                Button(working ? "正在处理…" : (result == nil ? "识别选中照片" : "已保存识别结果")) {
                    guard let selection else { return }
                    Task { await analyze(selection) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil || working || result != nil)
                if let result, result.writeState != .blocked {
                    if result.writeState == .pending {
                        Button("禁止写入这张照片") { showPrivacyConfirmation = true }.disabled(working)
                        if writeQueued {
                            Label("已审核，等待后台写入", systemImage: "clock")
                            Button("刷新写入状态") { if let selection { loadCached(selection) } }.disabled(working)
                        }
                        Button("编辑说明和关键词") {
                            draftDescription = result.description
                            draftKeywords = result.keywords.joined(separator: "，")
                            editError = ""
                            showEditor = true
                        }.disabled(working || writeQueued)
                        Button("审核后写入照片") { showWriteConfirmation = true }
                            .disabled(working || writeQueued)
                    } else if result.writeState == .writing || result.writeState == .needsVerification {
                        Button("核验上次写入") {
                            guard let selection else { return }
                            Task { await verifyWrite(selection) }
                        }.disabled(working)
                    } else if result.writeState == .verified {
                        if receipt?.status == "undone" {
                            Label("已撤销本次新增关键词", systemImage: "arrow.uturn.backward.circle")
                        } else {
                            Label("已写入并回读验证", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                            if let receipt, receipt.status == "ready", !receipt.addedKeywords.isEmpty {
                                Button("撤销本次新增关键词") { showUndoConfirmation = true }.disabled(working)
                            } else if receipt?.status == "undoing" || receipt?.status == "needs_review" {
                                Text("撤销结果需要人工检查，不会自动重试。")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Divider()
                Text("人物名称").font(.headline)
                if let names = personNames {
                    Text(names.isEmpty ? "未找到已命名人物。" : names.joined(separator: " · "))
                        .textSelection(.enabled)
                    if !names.isEmpty {
                        Text("来自照片人物索引，请确认匹配；不包含未命名人物和宠物。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(personNames == nil ? "读取人物和地点" : "更新人物和地点") {
                    guard let selection else { return }
                    Task { await readPeople(selection) }
                }.disabled(selection == nil || working)
                if let operation = peopleOperation, operation.state == "writing" || operation.state == "needs_verification" {
                    Text("人物写入结果待核验：\(operation.addedKeywords.joined(separator: " · "))")
                        .font(.caption).foregroundStyle(.orange)
                    Button("核验人物写入") { Task { await verifyPeople(operation.id, assetID: operation.assetID) } }.disabled(working)
                } else if let operation = peopleOperation, operation.state == "prepared" {
                    Text("未开始的人物写入：\(operation.addedKeywords.joined(separator: " · "))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("继续人物写入") { showPeopleConfirmation = true }.disabled(working)
                    Button("取消未开始的人物写入") { cancelPeople(operation) }.disabled(working)
                } else if let operation = peopleOperation, operation.state == "undoing" || operation.state == "undo_uncertain" {
                    Text("人物关键词撤销结果待核验。") .font(.caption).foregroundStyle(.orange)
                    Button("核验人物撤销") { Task { await verifyPeopleUndo(operation.id, assetID: operation.assetID) } }.disabled(working)
                } else {
                    if let operation = peopleOperation, operation.state == "verified" {
                        Label("人物关键词已写入并核验", systemImage: "checkmark.circle").foregroundStyle(.green)
                        if operation.undoEligible {
                            Button("撤销本次新增人物名称") { showPeopleUndoConfirmation = true }.disabled(working)
                        } else {
                            Text("本次写入曾中断，来源无法完全确认，不提供自动撤销。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if peopleOperation?.state == "undone" {
                        Label("已撤销本次人物关键词", systemImage: "arrow.uturn.backward.circle")
                    }
                    if let names = personNames, !names.isEmpty {
                        if let result, result.writeState != .blocked {
                            Button("审核后追加人物关键词") { showPeopleConfirmation = true }.disabled(working)
                        } else {
                            Text(result?.writeState == .blocked ? "这张照片已禁止写入。" : "请先完成 AI 识别。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("地点信息").font(.headline)
                if let location {
                    switch location.status {
                    case .localAddress:
                        Text(location.keywords.joined(separator: " · ")).textSelection(.enabled)
                        Text("来自照片已有的本地地址记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    case .noCoordinates: Text("照片没有定位坐标。")
                    case .invalidCoordinates: Text("照片的定位坐标无效。")
                    case .coordinatesNoLocalAddress: Text("照片有定位坐标，但没有已保存的地址。")
                    case .readError: Text("无法读取照片的地点信息。")
                    }
                } else {
                    Text("读取人物和地点后显示已有地址。")
                }
                if let operation = locationOperation, operation.state == "writing" || operation.state == "needs_verification" {
                    Text("地点写入结果待核验：\(operation.addedKeywords.joined(separator: " · "))").font(.caption).foregroundStyle(.orange)
                    Button("核验地点写入") { Task { await verifyPeople(operation.id, assetID: operation.assetID, isLocation: true) } }.disabled(working)
                } else if let operation = locationOperation, operation.state == "prepared" {
                    Text("未开始的地点写入：\(operation.addedKeywords.joined(separator: " · "))").font(.caption)
                    Button("继续地点写入") { showLocationConfirmation = true }.disabled(working)
                    Button("取消未开始的地点写入") { cancelPeople(operation, isLocation: true) }.disabled(working)
                } else if let operation = locationOperation, operation.state == "undoing" || operation.state == "undo_uncertain" {
                    Text("地点关键词撤销结果待核验。").font(.caption).foregroundStyle(.orange)
                    Button("核验地点撤销") { Task { await verifyPeopleUndo(operation.id, assetID: operation.assetID, isLocation: true) } }.disabled(working)
                } else {
                    if let operation = locationOperation, operation.state == "verified" {
                        Label("地点关键词已写入并核验", systemImage: "checkmark.circle").foregroundStyle(.green)
                        if operation.undoEligible {
                            Button("撤销本次新增地点") { showLocationUndoConfirmation = true }.disabled(working)
                        } else {
                            Text("本次写入曾中断，来源无法完全确认，不提供自动撤销。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if locationOperation?.state == "undone" {
                        Label("已撤销本次地点关键词", systemImage: "arrow.uturn.backward.circle")
                    }
                    if location?.status == .localAddress, let result, result.writeState != .blocked {
                        Button("审核后追加地点关键词") { showLocationConfirmation = true }.disabled(working)
                    }
                }
                Text("只使用本地预览，不下载 iCloud 原片。写入前会保存原始说明和关键词。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 280, idealWidth: 340)
        }
        .navigationTitle("照片浏览")
        .task {
            loadRecent()
            if let initialAssetID { selection = initialAssetID; loadCached(initialAssetID) }
        }
        .onDisappear { if let client = peopleClient { Task { await client.stop() } } }
        .confirmationDialog("撤销本次新增人物名称？", isPresented: $showPeopleUndoConfirmation) {
            Button("确认撤销") {
                guard let operation = peopleOperation else { return }
                Task { await undoPeople(operation) }
            }
        } message: {
            Text("只移除本次新增的人物关键词，保留原有关键词和说明；照片已变化时会停止。")
        }
        .confirmationDialog("撤销本次新增地点？", isPresented: $showLocationUndoConfirmation) {
            Button("确认撤销") {
                guard let operation = locationOperation else { return }
                Task { await undoPeople(operation, isLocation: true) }
            }
        } message: {
            Text("只移除本次新增的地点关键词，保留原有关键词和说明；照片已变化时会停止。")
        }
        .confirmationDialog("追加地点关键词？", isPresented: $showLocationConfirmation) {
            Button("确认追加") {
                guard let selection else { return }
                Task { await writePeople(selection, isLocation: true) }
            }
        } message: {
            Text("仅追加照片已有的本地地址名称，保留原有说明和关键词。请先核对地点。")
        }
        .confirmationDialog("追加人物名称？", isPresented: $showPeopleConfirmation) {
            Button("确认追加") {
                guard let selection else { return }
                Task { await writePeople(selection) }
            }
        } message: {
            Text("仅追加照片人物索引中已命名的人物，保留原有说明和关键词。请先确认人物匹配正确。")
        }
        .sheet(isPresented: $showEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("编辑识别结果").font(.title2.bold())
                Text("照片说明").font(.headline)
                TextEditor(text: $draftDescription).frame(height: 100).border(.quaternary)
                Text("关键词（使用逗号分隔）").font(.headline)
                TextField("关键词", text: $draftKeywords)
                if !editError.isEmpty { Text(editError).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("取消") { showEditor = false }
                    Button("保存") { saveEdit() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 520)
        }
        .confirmationDialog("写入这张照片？", isPresented: $showWriteConfirmation) {
            Button("确认写入") {
                guard let selection else { return }
                Task { await writeSelected(selection) }
            }
            Button("确认并交给后台写入") {
                guard let selection else { return }
                Task { await queueSelected(selection) }
            }
        } message: {
            Text("将追加显示的关键词；仅当原说明为空时写入 AI 说明。请先确认识别结果准确。")
        }
        .confirmationDialog("禁止写入这张照片？", isPresented: $showPrivacyConfirmation) {
            Button("禁止写入并取消排队") {
                guard let selection else { return }
                markSensitive(selection)
            }
        } message: {
            Text("会阻止 AI、人物和地点关键词写入，并取消尚未开始的写入任务。已开始或结果不确定的操作须先核验。照片的原说明和关键词保持不变。")
        }
        .confirmationDialog("撤销本次新增的关键词？", isPresented: $showUndoConfirmation) {
            Button("确认撤销") {
                guard let selection else { return }
                Task { await undoSelected(selection) }
            }
        } message: {
            Text("仅移除本次新增的关键词，保留原有关键词和说明。如果元数据已经发生变化，将停止撤销。")
        }
    }

    @MainActor private func loadRecent() {
        guard !AppEnvironment.isUITest else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        total = assets.count
        let range = Pagination.range(offset: offset, pageSize: 48, total: total)
        offset = range.lowerBound
        ids = range.map { assets.object(at: $0).localIdentifier }
        selection = nil
        result = nil
        receipt = nil
        writeQueued = false
        manualPrivacy = false
        legacy = nil
        personNames = nil
        location = nil
        peopleOperation = nil
        locationOperation = nil
    }

    @MainActor private func photosAllowed() -> Bool {
        guard !AppEnvironment.isUITest else { message = "独立界面测试不会读取或写入真实照片。"; return false }
        return true
    }

    @MainActor private func store() throws -> Store {
        try Store(url: AppEnvironment.database)
    }

    @MainActor private func loadCached(_ id: String) {
        do {
            let db = try store()
            result = try db.result(assetID: id)
            receipt = try db.writeReceipt(assetID: id)
            writeQueued = try db.hasQueuedWrite(assetID: id)
            manualPrivacy = try db.hasManualPrivacyDecision(assetID: id)
            personNames = try db.personCandidates(assetID: id)
            location = try db.locationCandidates(assetID: id)
            peopleOperation = try db.latestPeopleOperation(assetID: id)
            locationOperation = try db.latestLocationOperation(assetID: id)
            legacy = result == nil ? try db.legacySuggestion(localIdentifier: id) : nil
            message = result == nil ? "这张照片尚无新版本识别结果。" : "已显示本机保存的结果。"
        } catch {
            result = nil
            receipt = nil
            writeQueued = false
            manualPrivacy = false
            legacy = nil
            personNames = nil
            location = nil
            peopleOperation = nil
            locationOperation = nil
            message = "无法读取本机缓存，请检查磁盘和应用权限。"
        }
    }

    @MainActor private func readPeople(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            if selection == id { message = "正在读取人物和地点索引，首次加载可能需要一些时间…" }
            _ = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            let client: PeopleClient
            if let existing = peopleClient { client = existing }
            else {
                let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI-Photo-Manager/.venv/bin/python")
                guard let script = Bundle.main.resourceURL?.appendingPathComponent("people_index.py") else { throw PeopleClientError.unavailable }
                client = PeopleClient(executable: python, script: script)
                peopleClient = client
            }
            let candidates = try await client.candidates(for: id)
            let db = try store()
            try db.recordPersonCandidates(assetID: id, names: candidates.names)
            if let value = candidates.location { try db.recordLocationCandidates(assetID: id, value: value) }
            if selection == id { personNames = candidates.names; location = candidates.location; peopleOperation = try db.latestPeopleOperation(assetID: id); message = "人物和地点候选已读取，请核对后再添加。" }
        } catch {
            if selection == id { message = "无法读取人物索引，请检查旧版环境、图库文件权限和可用磁盘空间。" }
        }
    }

    @MainActor private func refreshIndexedOperation(_ db: Store, assetID: String, isLocation: Bool) throws {
        if isLocation { locationOperation = try db.latestLocationOperation(assetID: assetID) }
        else { peopleOperation = try db.latestPeopleOperation(assetID: assetID) }
    }

    @MainActor private func writePeople(_ id: String, isLocation: Bool = false) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        var operationID: String?
        var started = false
        do {
            let db = try store()
            let before = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            let previous = try isLocation ? db.latestLocationOperation(assetID: id) : db.latestPeopleOperation(assetID: id)
            let operation: PeopleWriteOperation
            if let previous, previous.state == "prepared" {
                guard previous.beforeDescription == before.description && previous.beforeKeywords == before.keywords else { throw StoreError.invalidTransition }
                operation = previous
            } else {
                let prepared = try isLocation ? db.prepareLocationWrite(assetID: id, description: before.description, keywords: before.keywords) : db.preparePeopleWrite(assetID: id, description: before.description, keywords: before.keywords)
                guard let prepared else {
                    if selection == id { message = "\(isLocation ? "地点" : "人物名称")已存在，无需重复添加。" }
                    return
                }
                operation = prepared
            }
            operationID = operation.id
            try db.beginPeopleWrite(operationID: operation.id)
            started = true
            _ = try await Task.detached(priority: .utility) {
                try PhotosAdapter.write(id: id, before: before, description: "", keywords: operation.addedKeywords)
            }.value
            try db.markPeopleWriteReturned(operationID: operation.id)
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            try db.confirmPeopleWrite(operationID: operation.id, description: after.description, keywords: after.keywords)
            if selection == id { try refreshIndexedOperation(db, assetID: id, isLocation: isLocation); message = "\(isLocation ? "地点" : "人物")关键词已追加并回读核验。" }
        } catch {
            if started, let operationID, let db = try? store() { try? db.markPeopleNeedsVerification(operationID: operationID) }
            if selection == id {
                if let db = try? store() { try? refreshIndexedOperation(db, assetID: id, isLocation: isLocation) }
                message = started ? "写入结果不确定，请先核验，不会自动重试。" : "写入前检查未通过，照片未修改。"
            }
        }
    }

    @MainActor private func verifyPeople(_ operationID: String, assetID: String, isLocation: Bool = false) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            let db = try store()
            if try db.peopleWriteState(operationID: operationID) == "writing" { try db.markPeopleNeedsVerification(operationID: operationID) }
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: assetID) }.value
            try db.confirmPeopleWrite(operationID: operationID, description: after.description, keywords: after.keywords)
            if selection == assetID { try refreshIndexedOperation(db, assetID: assetID, isLocation: isLocation); message = "关键词已重新读取并核验。" }
        } catch {
            if selection == assetID { message = "无法确认写入结果，请在照片应用中检查；不会自动重试。" }
        }
    }

    @MainActor private func undoPeople(_ operation: PeopleWriteOperation, isLocation: Bool = false) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        var started = false
        do {
            let db = try store()
            try db.beginPeopleUndo(operationID: operation.id)
            started = true
            _ = try await Task.detached(priority: .utility) { try PhotosAdapter.undoPeople(id: operation.assetID, operation: operation) }.value
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: operation.assetID) }.value
            try db.confirmPeopleUndo(operationID: operation.id, description: after.description, keywords: after.keywords)
            if selection == operation.assetID { try refreshIndexedOperation(db, assetID: operation.assetID, isLocation: isLocation); message = "已撤销本次新增关键词并回读核验。" }
        } catch {
            if started, let db = try? store() { try? db.markPeopleUndoUncertain(operationID: operation.id) }
            if selection == operation.assetID {
                if let db = try? store() { try? refreshIndexedOperation(db, assetID: operation.assetID, isLocation: isLocation) }
                message = started ? "撤销结果不确定，请先核验；不会自动重试。" : "无法开始撤销。"
            }
        }
    }

    @MainActor private func verifyPeopleUndo(_ operationID: String, assetID: String, isLocation: Bool = false) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            let db = try store()
            if try db.peopleWriteState(operationID: operationID) == "undoing" { try db.markPeopleUndoUncertain(operationID: operationID) }
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: assetID) }.value
            try db.confirmPeopleUndo(operationID: operationID, description: after.description, keywords: after.keywords)
            if selection == assetID { try refreshIndexedOperation(db, assetID: assetID, isLocation: isLocation); message = "关键词撤销已核验。" }
        } catch {
            if selection == assetID { message = "无法确认撤销结果，请在照片应用中检查；不会自动重试。" }
        }
    }

    @MainActor private func cancelPeople(_ operation: PeopleWriteOperation, isLocation: Bool = false) {
        do {
            let db = try store()
            try db.cancelPreparedPeopleWrite(operationID: operation.id)
            try refreshIndexedOperation(db, assetID: operation.assetID, isLocation: isLocation)
            message = "已取消未开始的写入。"
        } catch { message = "无法取消该操作，请检查当前状态。" }
    }

    @MainActor private func useLegacy(_ suggestion: LegacySuggestion) {
        guard let selection else { return }
        do {
            let db = try store()
            let value = suggestion.result
            try db.cache(assetID: selection, description: value.description, keywords: value.keywords,
                         sensitive: value.sensitive, category: value.category,
                         origin: "legacy:\(suggestion.source):\(suggestion.line)")
            result = try db.result(assetID: selection)
            legacy = nil
            message = "旧结果已保存，请核对后再写入。"
        } catch {
            message = "无法采用旧结果，请检查本机记录后重试。"
        }
    }

    @MainActor private func saveEdit() {
        guard let selection else { return }
        do {
            let parts = draftKeywords.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            let db = try store()
            try db.editPending(assetID: selection, description: draftDescription, keywords: parts)
            result = try db.result(assetID: selection)
            message = "编辑结果已保存在本机，请确认后写入。"
            showEditor = false
        } catch {
            editError = "无法保存。请检查说明和关键词，已开始写入的结果无法修改。"
        }
    }

    @MainActor private func markSensitive(_ id: String) {
        do {
            try store().markPendingSensitive(assetID: id)
            if selection == id { loadCached(id); message = "已禁止写入这张照片，排队任务已取消。" }
        } catch {
            if selection == id { message = "无法标记：请先暂停后台，等待正在进行的写入结束，或核验不确定的操作。" }
        }
    }

    @MainActor private func queueSelected(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            let before = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            try store().approveWrite(assetID: id, description: before.description, keywords: before.keywords)
            ScanController.shared.resume()
            if selection == id {
                loadCached(id)
                message = "已审核并加入后台写入队列，可在智能扫描查看进度。"
            }
        } catch {
            if selection == id { message = "未能加入写入队列，照片未修改，请检查权限和当前元数据。" }
        }
    }

    @MainActor private func writeSelected(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        var started = false
        do {
            let db = try store()
            guard let cached = try db.result(assetID: id), cached.writeState == .pending else {
                throw StoreError.invalidTransition
            }
            let before = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            if let prior = try db.snapshot(assetID: id) {
                guard prior.description == before.description && prior.keywords == before.keywords else { throw StoreError.invalidTransition }
            } else {
                try db.saveSnapshot(assetID: id, description: before.description, keywords: before.keywords)
            }
            try db.beginWrite(assetID: id)
            started = true
            _ = try await Task.detached(priority: .utility) {
                try PhotosAdapter.write(id: id, before: before, description: cached.description, keywords: cached.keywords)
            }.value
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            try db.confirmWrite(assetID: id, description: after.description, keywords: after.keywords)
            if selection == id { result = try db.result(assetID: id); receipt = try db.writeReceipt(assetID: id); message = "写入完成，已重新读取并核验。" }
        } catch {
            if started, let db = try? store() { try? db.markNeedsVerification(assetID: id) }
            if selection == id {
                result = try? store().result(assetID: id)
                message = started ? "写入结果尚不确定，请先核验，切勿重复写入。" : "写入前检查未通过，照片未修改。请检查 Photos 自动化权限及元数据是否发生变化。"
            }
        }
    }

    @MainActor private func verifyWrite(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            let db = try store()
            if try db.hasQueuedWrite(assetID: id), WorkerLease.isHeld(directory: ScanController.shared.database.deletingLastPathComponent()) {
                if selection == id { message = "后台仍在运行，请暂停并等待当前操作保存后再核验。" }
                return
            }
            if try db.result(assetID: id)?.writeState == .writing { try db.markNeedsVerification(assetID: id) }
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            try db.confirmWrite(assetID: id, description: after.description, keywords: after.keywords)
            if selection == id { result = try db.result(assetID: id); message = "已重新读取并确认写入结果。" }
        } catch {
            if selection == id { message = "尚无法确认写入结果，请在照片应用中检查原始内容；不会自动重试。" }
        }
    }

    @MainActor private func undoSelected(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        var started = false
        do {
            let db = try store()
            guard let record = try db.writeReceipt(assetID: id), record.status == "ready" else { throw StoreError.invalidTransition }
            try db.beginUndo(assetID: id)
            started = true
            _ = try await Task.detached(priority: .utility) { try PhotosAdapter.undo(id: id, receipt: record) }.value
            let after = try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            try db.finishUndo(assetID: id, description: after.description, keywords: after.keywords)
            if selection == id { receipt = try db.writeReceipt(assetID: id); message = "已撤销本次新增的关键词并回读核验。" }
        } catch {
            if started, let db = try? store() { try? db.markUndoNeedsReview(assetID: id) }
            if selection == id {
                receipt = try? store().writeReceipt(assetID: id)
                message = started ? "撤销结果尚不确定，请在照片应用中检查；不会自动重试。" : "未能开始撤销，请检查记录。"
            }
        }
    }

    @MainActor private func analyze(_ id: String) async {
        guard photosAllowed() else { return }
        working = true
        defer { working = false }
        do {
            let db = try store()
            if let cached = try db.result(assetID: id) {
                if selection == id { result = cached; message = "使用已保存的结果，无需重复识别。" }
                return
            }
            guard let image = await LocalPreview.jpeg(id: id, size: 768) else {
                if selection == id { message = "未找到本地可用预览，已跳过；没有下载 iCloud 原片。" }
                return
            }
            if selection == id { message = "正在本机识别，请稍候…" }
            let output = try await Ollama.infer(image: image)
            try db.cache(assetID: id, description: output.description, keywords: output.keywords, sensitive: output.sensitive, category: output.category)
            if selection == id {
                result = try db.result(assetID: id)
                message = "识别结果已保存在本机，等待审核。"
            }
        } catch {
            if selection == id { message = "识别或保存失败，请检查 Ollama 和磁盘状态后重试。" }
        }
    }
}

struct Thumbnail: View {
    let id: String
    var fit = false
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill) }
            else { Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
        }
        .frame(height: fit ? 220 : 110).frame(maxWidth: .infinity)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: id) {
            guard !AppEnvironment.isUITest else { return }
            if let data = await LocalPreview.jpeg(id: id, size: fit ? 768 : 180) { image = NSImage(data: data) }
        }
    }
}

