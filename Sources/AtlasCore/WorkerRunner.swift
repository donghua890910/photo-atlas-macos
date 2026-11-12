import Foundation
import Photos
import IOKit.pwr_mgt
import Darwin

public enum WorkerRunner {
    public static func run(database url: URL) async -> Int32 {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 2 }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("people_index.py") else { return 3 }
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
            defer { try? control.setScanEnabled(false) }
            guard try control.scanEnabled() else { return 0 }
            try control.recoverInterruptedTasks()
            var power: IOPMAssertionID = 0
            let assertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                        "Photo Atlas background processing" as CFString, &power)
            defer { if assertion == kIOReturnSuccess { IOPMAssertionRelease(power) } }
            let engine = try ProcessingEngine(url: url, preview: { id in
                try await LocalPreview.requiredJPEG(id: id, size: 1536)
            }, analyze: { data in try await Ollama.infer(image: data) })
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
            try await writing.reconcileUncertainWrites()
            while !Task.isCancelled {
                guard try control.scanEnabled() else { break }
                try DiskSpace.read(at: url.deletingLastPathComponent()).requireCapacity()
                let writeStep = await writing.runOne()
                if writeStep == .unavailable { return 3 }
                if writeStep == .deferred { return 6 }
                if writeStep == .completed || writeStep == .skipped { continue }
                guard try control.scanEnabled() else { break }
                try DiskSpace.read(at: url.deletingLastPathComponent()).requireCapacity()
                let indexStep = await indexing.runOne()
                guard try control.scanEnabled() else { break }
                try DiskSpace.read(at: url.deletingLastPathComponent()).requireCapacity()
                let step = await engine.runOne()
                if step == .idle && indexStep == .idle {
                    let aiRemaining = try await engine.hasOutstanding()
                    let indexRemaining = try await indexing.hasOutstanding()
                    let writeRemaining = try await writing.hasOutstanding()
                    if !aiRemaining && !indexRemaining && !writeRemaining { break }
                }
                if step == .unavailable || indexStep == .unavailable { return 3 }
                if step != .completed && step != .skipped && indexStep != .completed {
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
