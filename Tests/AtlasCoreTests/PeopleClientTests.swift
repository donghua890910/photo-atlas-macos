import Foundation
import XCTest
@testable import AtlasCore

final class PeopleClientTests: XCTestCase {
    func testQueriesReuseOneHelperProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake.py")
        let source = """
        import json,sys
        print(json.dumps({'status':'ready'}),flush=True)
        count=0
        for line in sys.stdin:
            count+=1
            print(json.dumps({'status':'candidate','names':[str(count)]}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let client = PeopleClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), script: script)
        let first = try await client.names(for: "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001")
        let second = try await client.names(for: "A1B2C3D4-1111-4222-8333-123456789ABC/L0/040")
        XCTAssertEqual(first, ["1"])
        XCTAssertEqual(second, ["2"])
        await client.stop()
    }
    func testHelperExitIsReportedWithoutCrashingCaller() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("exit.py")
        try "import json; print(json.dumps({'status':'ready'}),flush=True)\n".write(to: script, atomically: true, encoding: .utf8)
        let client = PeopleClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), script: script)
        do {
            _ = try await client.names(for: "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001")
            XCTFail("helper terminated without a result")
        } catch { }
        await client.stop()
    }

    func testLocationComesFromTheSameIndexReply() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("location.py")
        let source = """
        import json,sys
        print(json.dumps({'status':'ready'}),flush=True)
        for line in sys.stdin:
            print(json.dumps({'status':'candidate','names':['Alice'],'location':{'status':'local_address','keywords':['Shanghai']}}),flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let client = PeopleClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), script: script)
        let value = try await client.candidates(for: "A1B2C3D4-1111-4222-8333-123456789ABC/L0/001")
        XCTAssertEqual(value.names, ["Alice"])
        XCTAssertEqual(value.location?.status, .localAddress)
        XCTAssertEqual(value.location?.keywords, ["Shanghai"])
        await client.stop()
    }

}
