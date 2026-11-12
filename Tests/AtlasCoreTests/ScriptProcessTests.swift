import XCTest
import Darwin
@testable import AtlasCore

final class ScriptProcessTests: XCTestCase {
    private let python = URL(fileURLWithPath: "/usr/bin/python3")

    func testDrainsLargeOutputBeforeWaitingForExit() throws {
        let data = try ScriptProcess.run(executable: python, arguments: ["-c", "import sys;sys.stdout.buffer.write(b'x'*262144);sys.stdout.flush()"], input: Data(), timeout: 5)
        XCTAssertEqual(data.count, 262144)
        XCTAssertEqual(Set(data), [UInt8(120)])
    }

    func testDrainsOutputWhileSendingInputAndRejectsOutputOverflow() throws {
        let payload = Data(repeating: 65, count: 16_000)
        let code = "import sys;sys.stdout.buffer.write(b'x'*262144);sys.stdout.flush();sys.stdout.buffer.write(sys.stdin.buffer.read());sys.stdout.flush()"
        let data = try ScriptProcess.run(executable: python, arguments: ["-c", code], input: payload, timeout: 5)
        XCTAssertEqual(data.count, 262144 + payload.count)
        XCTAssertEqual(data.suffix(payload.count), payload)
        XCTAssertThrowsError(try ScriptProcess.run(executable: python, arguments: ["-c", code], input: payload, timeout: 5, maximumOutput: 1024))
    }

    func testTimeoutKillsAndReapsScriptThatIgnoresTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let code = "import os,signal,sys,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(30)"
        XCTAssertThrowsError(try ScriptProcess.run(executable: python, arguments: ["-c", code, marker.path], input: Data(), timeout: 2)) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testEarlyScriptExitDoesNotCrashCallerWithBrokenPipe() {
        XCTAssertThrowsError(try ScriptProcess.run(executable: python, arguments: ["-c", "import sys;sys.exit(7)"], input: Data(repeating: 65, count: 16_000), timeout: 5))
    }
}
