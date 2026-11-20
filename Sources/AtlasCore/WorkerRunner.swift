import Foundation
import Photos
import IOKit.pwr_mgt
import Darwin

public enum WorkerRunner {
    public static func run(database url: URL) async -> Int32 {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 2 }
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let script: URL
        if Bundle.main.bundleIdentifier != nil, let resources = Bundle.main.resourceURL {
            script = resources.appendingPathComponent("people_index.py")
        } else {
            script = helper.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/people_index.py")
        }
        guard FileManager.default.isReadableFile(atPath: script.path) else { return 3 }
        let client = PeopleClient(executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AI-Photo-Manager/.venv/bin/python"), script: script)
        let outcome = await runAuthorized(database: url, client: client)
        await client.stop()
        return outcome
    }

    private static func runAuthorized(database url: URL, client: PeopleClient) async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lease = WorkerLease(directory: url.deletingLastPathComponent()) else { return 4 }
            defer { withExtendedLifetime(lease) {} }
            let control = try Store(url: url)
            guard try control.scanEnabled() else { return 0 }
            let directory = url.deletingLastPathComponent()
            WorkerSupervisor.heartbeat(directory: directory, stage: "恢复任务")
            try control.recoverInterruptedTasks()
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Run a user-requested photo scan")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var power: IOPMAssertionID = 0
            let assertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                        "Photo Atlas background processing" as CFString, &power)
            defer { if assertion == kIOReturnSuccess { IOPMAssertionRelease(power) } }
            let engine = try ProcessingEngine(url: url, preview: { id in
                try await LocalPreview.requiredJPEG(id: id, size: 1536)
            }, analyze: { data in
                try await Ollama.infer(image: data, ocrExecutable: URL(fileURLWithPath: CommandLine.arguments[0]))
            })
            let indexing = try IndexingEngine(url: url, lookup: { id in
                let exists = await Task.detached(priority: .utility) {
                    let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
                    return asset?.localIdentifier == id
                }.value
                guard exists else { throw PreviewFailure.assetUnavailable }
                return try await client.candidates(for: id)
            })
            let writing = try WriteEngine(url: url, read: { id in
                try await Task.detached(priority: .utility) { try PhotosAdapter.read(id: id) }.value
            }, write: { id, before, description, keywords in
                _ = try await Task.detached(priority: .utility) {
                    try PhotosAdapter.write(id: id, before: before, description: description, keywords: keywords)
                }.value
            })
            try await writing.reconcileUncertainWrites {
                WorkerSupervisor.heartbeat(directory: directory, stage: "核验写入")
            }
            while !Task.isCancelled {
                guard try control.scanEnabled() else { break }
                try DiskSpace.read(at: directory).requireCapacity()
                WorkerSupervisor.heartbeat(directory: directory, stage: "识别照片与更新元数据")
                async let recognition = engine.runOne()
                var writeStep = WorkerStep.idle
                var wrote = false
                // Preparing a snapshot and writing it are two steps. Keep one writer
                // and limit backlog work per round so it cannot monopolize the scan.
                for _ in 0..<3 {
                    guard try control.scanEnabled() else { break }
                    try DiskSpace.read(at: directory).requireCapacity()
                    writeStep = await writing.runOne()
                    guard writeStep == .completed || writeStep == .skipped else { break }
                    wrote = true
                }
                let indexStep = try control.scanEnabled() && writeStep != .unavailable && writeStep != .deferred
                    ? await indexing.runOne() : .idle
                let step = await recognition
                if writeStep == .unavailable { return 3 }
                if writeStep == .deferred { return 6 }
                guard try control.scanEnabled() else { break }
                if step == .idle && indexStep == .idle && !wrote {
                    let aiRemaining = try await engine.hasOutstanding()
                    let indexRemaining = try await indexing.hasOutstanding()
                    let writeRemaining = try await writing.hasOutstanding()
                    if !aiRemaining && !indexRemaining && !writeRemaining {
                        try control.setScanEnabled(false)
                        break
                    }
                }
                if step == .unavailable || indexStep == .unavailable { return 3 }
                if step != .completed && step != .skipped && indexStep != .completed && !wrote {
                    for _ in 0..<20 {
                        guard try control.scanEnabled() else { return 0 }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
            return 0
        } catch ResourceError.diskSpaceLow { return 5 }
        catch { return 3 }
    }
}
