import XCTest
@testable import AtlasCore

final class WorkerSupervisorTests: XCTestCase {
    func testHungWorkerIsTerminatedAndQueueRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("atlas.sqlite")
        let store = try Store(url: database)
        try store.setScanEnabled(true)
        let script = directory.appendingPathComponent("worker.sh")
        try """
        #!/bin/sh
        marker="${2%/*}/started"
        if [ -f "$marker" ]; then
            /usr/bin/sqlite3 "$2" 'UPDATE scan_control SET enabled=0 WHERE id=1;'
            exit 0
        fi
        : > "$marker"
        /bin/sleep 30 &
        echo $! > "${2%/*}/helper-pid"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let stopper = DispatchWorkItem {
            guard FileManager.default.fileExists(atPath: database.path) else { return }
            try? Store(url: database).setScanEnabled(false)
        }
        defer { stopper.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: stopper)
        let started = Date()
        let result = await Task.detached {
            WorkerSupervisor.run(database: database, executable: script, stallSeconds: 0.3, pollSeconds: 0.05, restartSeconds: 0.05)
        }.value
        XCTAssertEqual(result, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        XCTAssertFalse(try store.scanEnabled())
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let pidText = try String(contentsOf: directory.appendingPathComponent("helper-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "The stalled worker's helper must also be stopped")
    }
}
