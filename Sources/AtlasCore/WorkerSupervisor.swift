import Foundation
import Darwin
import IOKit.pwr_mgt
import OSLog

/// A separate process can restart a worker blocked in a system framework.
public enum WorkerSupervisor {
    private static let heartbeatName = "worker-heartbeat"
    private static let logger = Logger(subsystem: "local.photoatlas.next", category: "supervisor")
    public static let leaseName = "supervisor.lock"

    static func heartbeat(directory: URL, stage: String) {
        let file = directory.appendingPathComponent(heartbeatName)
        let data = Data("\(stage) \(UUID().uuidString)".utf8)
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func run(database: URL, executable: URL,
                           stallSeconds: TimeInterval = 540,
                           pollSeconds: TimeInterval = 2,
                           restartSeconds: TimeInterval = 5) -> Int32 {
        guard stallSeconds > 0, pollSeconds > 0, restartSeconds > 0 else { return 3 }
        let directory = database.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lease = WorkerLease(directory: directory, name: leaseName) else { return 4 }
            defer { withExtendedLifetime(lease) {} }
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Supervise a user-requested photo scan")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var power: IOPMAssertionID = 0
            let assertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                        "Photo Atlas background supervision" as CFString, &power)
            defer { if assertion == kIOReturnSuccess { IOPMAssertionRelease(power) } }
            let control = try Store(url: database)
            let heartbeatFile = directory.appendingPathComponent(heartbeatName)
            defer { try? FileManager.default.removeItem(at: heartbeatFile) }
            var failures = 0
            while try control.scanEnabled() {
                heartbeat(directory: directory, stage: "启动后台")
                let started = ProcessInfo.processInfo.systemUptime
                guard let child = spawn(executable: executable, database: database) else {
                    failures += 1
                    Thread.sleep(forTimeInterval: min(60, restartSeconds * Double(min(failures, 12))))
                    continue
                }
                var previous = try? Data(contentsOf: heartbeatFile)
                var lastChange = ProcessInfo.processInfo.systemUptime
                var status: Int32 = 0
                while true {
                    let result = waitpid(child, &status, WNOHANG)
                    if result == child || (result < 0 && errno != EINTR) {
                        kill(-child, SIGKILL)
                        break
                    }
                    let current = try? Data(contentsOf: heartbeatFile)
                    if current != previous {
                        previous = current
                        lastChange = ProcessInfo.processInfo.systemUptime
                    }
                    if ProcessInfo.processInfo.systemUptime - lastChange >= stallSeconds {
                        let stage = previous.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: " ").first.map(String.init) ?? "未知阶段"
                        logger.error("后台操作超时，正在恢复：\(stage, privacy: .public)")
                        // Terminate the worker's process group before retrying its interrupted tasks.
                        kill(-child, SIGTERM)
                        Thread.sleep(forTimeInterval: 2)
                        let waited = waitpid(child, &status, WNOHANG)
                        kill(-child, SIGKILL)
                        if waited == 0 {
                            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                        }
                        break
                    }
                    Thread.sleep(forTimeInterval: pollSeconds)
                }
                guard (try? control.scanEnabled()) == true else { break }
                failures = ProcessInfo.processInfo.systemUptime - started >= 120 ? 0 : failures + 1
                Thread.sleep(forTimeInterval: min(60, restartSeconds * Double(max(1, min(failures, 12)))))
            }
            return 0
        } catch { return 3 }
    }

    private static func spawn(executable: URL, database: URL) -> pid_t? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { return nil }
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable.path, "--worker", database.path].map { value in
            value.withCString { strdup($0) }
        }
        arguments.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { key, value in
            "\(key)=\(value)".withCString { strdup($0) }
        }
        environment.append(nil)
        defer {
            arguments.compactMap { $0 }.forEach { free($0) }
            environment.compactMap { $0 }.forEach { free($0) }
        }
        var child: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { envp in
                posix_spawn(&child, executable.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress), UnsafeMutablePointer(mutating: envp.baseAddress))
            }
        }
        return result == 0 && child > 1 ? child : nil
    }
}
