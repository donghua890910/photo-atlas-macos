import Foundation
import Darwin

public enum PeopleClientError: Error { case unavailable, busy, diskLow, invalidReply, timedOut }

public struct PhotoIndexCandidates: Sendable {
    public let names: [String]
    public let location: LocationCandidates?
}

/// Keeps one private helper alive for repeated lookups; names travel only through pipes.
public actor PeopleClient {
    private struct Reply: Decodable { let status: String; let names: [String]?; let location: LocationCandidates? }
    private let executable: URL
    private let script: URL
    private var child: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    public init(executable: URL, script: URL) {
        self.executable = executable
        self.script = script
    }

    public func names(for localIdentifier: String) throws -> [String] {
        try candidates(for: localIdentifier).names
    }

    public func candidates(for localIdentifier: String) throws -> PhotoIndexCandidates {
        guard PersonKeywords.assetUUID(for: localIdentifier) != nil else { throw StoreError.invalidInput }
        do {
            if child == nil || child?.isRunning != true { try start() }
            let data = try JSONSerialization.data(withJSONObject: ["id": localIdentifier])
            guard data.count <= 4095, let input else { throw PeopleClientError.invalidReply }
            try input.write(contentsOf: data + Data([10]))
            let reply = try JSONDecoder().decode(Reply.self, from: readLine(timeout: 90))
            guard reply.status == "candidate", let names = reply.names, names.count <= 100,
                  names.allSatisfy({ $0.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw PeopleClientError.invalidReply
            }
            if let location = reply.location {
                guard location.keywords.count <= 30,
                      location.keywords.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                      (location.status == .localAddress) == !location.keywords.isEmpty else {
                    throw PeopleClientError.invalidReply
                }
            }
            return PhotoIndexCandidates(names: PersonKeywords.plan(existing: [], names: names).additions, location: reply.location)
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        try? input?.close()
        input = nil
        try? output?.close()
        output = nil
        if let child, child.isRunning { child.terminate() }
        child = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func start() throws {
        stop()
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isReadableFile(atPath: script.path) else {
            throw PeopleClientError.unavailable
        }
        let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-u", script.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["PYTHONNOUSERSITE"] = "1"
        process.environment = environment
        try process.run()
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        let ready = try JSONDecoder().decode(Reply.self, from: readLine(timeout: 90))
        switch ready.status {
        case "ready": return
        case "busy": throw PeopleClientError.busy
        case "disk_low": throw PeopleClientError.diskLow
        default: throw PeopleClientError.unavailable
        }
    }

    private func readLine(timeout: UInt64) throws -> Data {
        guard let output else { throw PeopleClientError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout * 1_000_000_000
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let result = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return result
            }
            guard buffer.count <= 131_072 else { throw PeopleClientError.invalidReply }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw PeopleClientError.timedOut }
            let remaining = min((deadline - now) / 1_000_000, 5_000)
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, Int32(max(1, remaining)))
            if polled < 0 { if errno == EINTR { continue }; throw PeopleClientError.unavailable }
            if polled == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw PeopleClientError.unavailable }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
