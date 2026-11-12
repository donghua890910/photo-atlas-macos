import Foundation
import Darwin

/// The operating system releases the lock even after a crash.
public final class WorkerLease {
    private let descriptor: Int32
    public init?(directory: URL) {
        let path = directory.appendingPathComponent("worker.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }
    deinit { close(descriptor) }

    public static func isHeld(directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("worker.lock").path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }
}
