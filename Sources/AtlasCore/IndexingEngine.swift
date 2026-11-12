import Foundation

public actor IndexingEngine {
    private let store: Store
    private let lookup: @Sendable (String) async throws -> PhotoIndexCandidates
    private let clock: @Sendable () -> Int64
    private var running = false

    public init(url: URL, lookup: @escaping @Sendable (String) async throws -> PhotoIndexCandidates,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        store = try Store(url: url)
        self.lookup = lookup
        self.clock = clock
    }

    public func hasOutstanding() throws -> Bool { try store.outstanding(kind: .gps) > 0 }

    public func runOne() async -> WorkerStep {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        let task: ClaimedTask
        do {
            guard let claimed = try store.claimNext(now: clock(), leaseSeconds: 300, kind: .gps) else { return .idle }
            task = claimed
        } catch { return .unavailable }
        do {
            try Task.checkCancellation()
            let value = try await lookup(task.assetID)
            try Task.checkCancellation()
            try store.cacheAndFinishIndex(id: task.id, token: task.token, now: clock(), value: value)
            return .completed
        } catch {
            try? store.failTask(id: task.id, token: task.token, now: clock())
            return .deferred
        }
    }
}
