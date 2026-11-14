import Foundation
import Darwin

/// Pumps both pipes while the script runs so output cannot block process completion.
enum ScriptProcess {
    static func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval = 25,
                    maximumOutput: Int = 1_048_576, maximumInput: Int = 16_000) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 120, (1...8_388_608).contains(maximumOutput),
              (1...8_000_000).contains(maximumInput), input.count <= maximumInput else { throw StoreError.invalidInput }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        try process.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        var inputOpen = true
        defer {
            if inputOpen { try? stdin.fileHandleForWriting.close() }
            try? stdout.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                let grace = DispatchTime.now().uptimeNanoseconds + 250_000_000
                while process.isRunning && DispatchTime.now().uptimeNanoseconds < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let inputFD = stdin.fileHandleForWriting.fileDescriptor, outputFD = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0,
              fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK) == 0 else { throw URLError(.cannotOpenFile) }
        var offset = 0, output = Data(), eof = false
        while true {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw URLError(.timedOut) }
            if inputOpen {
                if offset < input.count {
                    let count = input.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress?.advanced(by: offset), input.count - offset) }
                    if count > 0 { offset += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { throw URLError(.cannotWriteToFile) }
                }
                if offset == input.count { try stdin.fileHandleForWriting.close(); inputOpen = false }
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            while !eof {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(outputFD, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard output.count + count <= maximumOutput else { throw StoreError.invalidInput }
                    output.append(contentsOf: chunk.prefix(count))
                } else if count == 0 { eof = true }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { break }
                else { throw StoreError.database("无法读取照片脚本返回内容") }
            }
            if !process.isRunning && eof { break }
            var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = (deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000
            let result = Darwin.poll(&descriptor, 1, Int32(min(50, max(1, remaining))))
            if result < 0 && errno != EINTR { throw StoreError.database("无法读取照片脚本返回内容") }
            if eof { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard process.terminationStatus == 0 else { throw StoreError.database("照片自动化读取或写入失败") }
        return output
    }
}
