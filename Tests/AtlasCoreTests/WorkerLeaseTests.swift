import XCTest
@testable import AtlasCore

final class WorkerLeaseTests: XCTestCase {
    func testExclusiveLeaseAndReleaseReflectActualLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(WorkerLease.isHeld(directory: directory))
        do {
            let lease = try XCTUnwrap(WorkerLease(directory: directory))
            XCTAssertTrue(WorkerLease.isHeld(directory: directory))
            XCTAssertNil(WorkerLease(directory: directory))
            withExtendedLifetime(lease) { }
        }
        XCTAssertFalse(WorkerLease.isHeld(directory: directory))
        XCTAssertNotNil(WorkerLease(directory: directory))
    }
}
