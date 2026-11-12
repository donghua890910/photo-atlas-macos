import XCTest
@testable import AtlasCore

final class RuntimeResourcesTests: XCTestCase {
    func testDiskGuardStopsBelowReserveAndAllowsBoundary() throws {
        XCTAssertThrowsError(try DiskSpace(available: DiskSpace.minimumAvailable - 1, total: 2_000_000_000).requireCapacity())
        XCTAssertNoThrow(try DiskSpace(available: DiskSpace.minimumAvailable, total: 2_000_000_000).requireCapacity())
    }

    func testSamplerReadsRealProcessAndFilesystemWithoutInventingFirstCPUValue() async throws {
        let sampler = ResourceSampler()
        let directory = FileManager.default.temporaryDirectory
        let first = await sampler.sample(directory: directory)
        XCTAssertNil(first.appCPUPercent)
        XCTAssertGreaterThan(first.appPeakMemoryBytes ?? 0, 1_048_576)
        XCTAssertGreaterThan(first.physicalMemoryBytes, 0)
        XCTAssertGreaterThan(try XCTUnwrap(first.disk).total, 0)
        let second = await sampler.sample(directory: directory)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second.appCPUPercent), 0)
        XCTAssertGreaterThanOrEqual(second.appPeakMemoryBytes ?? 0, first.appPeakMemoryBytes ?? 0)
    }
}
