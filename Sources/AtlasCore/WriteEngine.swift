import Foundation

/// Writes only after a scan request or single-photo approval has saved original metadata.
public actor WriteEngine {
    private let store: Store
    private let read: @Sendable (String) async throws -> PhotoMetadata
    private let write: @Sendable (String, PhotoMetadata, String, [String]) async throws -> Void
    private let clock: @Sendable () -> Int64
    private var running = false
    private var retryAfter: [String: Int64] = [:]

    public init(url: URL, read: @escaping @Sendable (String) async throws -> PhotoMetadata,
                write: @escaping @Sendable (String, PhotoMetadata, String, [String]) async throws -> Void,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        store = try Store(url: url)
        self.read = read
        self.write = write
        self.clock = clock
    }
    public func hasOutstanding() throws -> Bool {
        let progress = try store.scanProgress()
        return progress.pendingWrites + progress.runningWrites > 0
    }

    func reconcileUncertainWrites() async throws {
        for id in try store.uncertainWriteAssetIDs() {
            guard !Task.isCancelled, try store.scanEnabled() else { break }
            try? await verifyUncertainWrite(assetID: id)
        }
    }

    private func verifyUncertainWrite(assetID: String) async throws {
        guard try store.result(assetID: assetID)?.writeState == .needsVerification else { throw StoreError.invalidTransition }
        let observed = try await read(assetID)
        guard observed.id == assetID else { throw StoreError.invalidTransition }
        try store.confirmWrite(assetID: assetID, description: observed.description, keywords: observed.keywords)
    }

    public func runOne() async -> WorkerStep {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        let task: ClaimedTask
        do {
            guard let claimed = try store.claimNext(now: clock(), leaseSeconds: 180, kind: .write) else {
                return await prepareAutomaticWrite()
            }
            task = claimed
        } catch { return .unavailable }
        do {
            try Task.checkCancellation()
            guard let result = try store.result(assetID: task.assetID), result.writeState == .writing,
                  let snapshot = try store.snapshot(assetID: task.assetID) else { throw StoreError.invalidTransition }
            let before = try await read(task.assetID)
            guard before.id == task.assetID, before.description == snapshot.description,
                  before.keywords == snapshot.keywords else { throw StoreError.invalidTransition }
            try Task.checkCancellation()
            try await write(task.assetID, before, result.description, result.keywords)
            let after = try await read(task.assetID)
            guard after.id == task.assetID else { throw StoreError.invalidTransition }
            try store.confirmAndFinishWrite(task: task, now: clock(), description: after.description, keywords: after.keywords)
            return .completed
        } catch {
            do {
                try store.failTask(id: task.id, token: task.token, now: clock())
            } catch {
                try? store.markNeedsVerification(assetID: task.assetID)
                return .deferred
            }
            do {
                try Task.checkCancellation()
                try await verifyUncertainWrite(assetID: task.assetID)
                return .completed
            } catch { return .skipped }
        }
    }

    private func prepareAutomaticWrite() async -> WorkerStep {
        let now = clock()
        retryAfter = retryAfter.filter { $0.value > now }
        let id: String
        do {
            guard let candidate = try store.nextAutomaticWrite(skipping: Set(retryAfter.keys)) else { return .idle }
            id = candidate
        } catch { return .unavailable }
        do {
            let before = try await read(id)
            guard before.id == id else { throw StoreError.invalidTransition }
            try Task.checkCancellation()
            do {
                try store.approveWrite(assetID: id, description: before.description, keywords: before.keywords, automatic: true)
            } catch StoreError.invalidTransition {
                // Pause, a privacy decision, or another write can win while Photos is being read.
                return .skipped
            }
            return .completed
        } catch {
            guard !Task.isCancelled else { return .deferred }
            retryAfter[id] = now <= Int64.max - 60 ? now + 60 : Int64.max
            return .skipped
        }
    }
}
