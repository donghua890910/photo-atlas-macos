import Foundation

public enum PreviewFailure: Error { case noLocalPreview, assetUnavailable }
public enum WorkerStep: Equatable, Sendable { case idle, completed, skipped, deferred, busy, unavailable }

public actor ProcessingEngine {
    private let store: Store
    private let preview: @Sendable (String) async throws -> Data
    private let analyze: @Sendable (Data) async throws -> AIResult
    private let clock: @Sendable () -> Int64
    private var running = false

    public init(url: URL,
                preview: @escaping @Sendable (String) async throws -> Data,
                analyze: @escaping @Sendable (Data) async throws -> AIResult,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        store = try Store(url: url)
        self.preview = preview
        self.analyze = analyze
        self.clock = clock
    }

    public func hasOutstanding() throws -> Bool { try store.outstanding(kind: .ai) > 0 }

    public func runOne() async -> WorkerStep {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        let task: ClaimedTask
        do {
            guard let claimed = try store.claimNext(now: clock(), leaseSeconds: 600, kind: .ai) else { return .idle }
            task = claimed
        } catch { return .unavailable }
        do {
            try Task.checkCancellation()
            if try store.result(assetID: task.assetID) != nil {
                try store.finishTask(id: task.id, token: task.token, now: clock())
                return .completed
            }
            let image = try await preview(task.assetID)
            try Task.checkCancellation()
            let result = try await analyze(image)
            try Task.checkCancellation()
            try store.cacheAndFinishAI(id: task.id, token: task.token, now: clock(), description: result.description,
                                       keywords: result.keywords, sensitive: result.sensitive, category: result.category)
            return .completed
        } catch PreviewFailure.noLocalPreview {
            do { try store.markNoLocalPreview(id: task.id, token: task.token, now: clock()); return .skipped }
            catch { return .deferred }
        } catch {
            try? store.failTask(id: task.id, token: task.token, now: clock())
            return .deferred
        }
    }
}
