import Foundation
import Darwin

public enum ResourceError: Error { case diskSpaceLow }

public struct DiskSpace: Sendable {
    public let available: UInt64
    public let total: UInt64
    public static let minimumAvailable: UInt64 = 1_073_741_824

    public static func read(at directory: URL) throws -> DiskSpace {
        let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let available = (values[.systemFreeSize] as? NSNumber)?.uint64Value,
              let total = (values[.systemSize] as? NSNumber)?.uint64Value else { throw StoreError.invalidInput }
        return DiskSpace(available: available, total: total)
    }
    public func requireCapacity() throws {
        guard available >= Self.minimumAvailable else { throw ResourceError.diskSpaceLow }
    }
}

public struct ResourceSnapshot: Sendable {
    public let appCPUPercent: Double?
    public let appPeakMemoryBytes: UInt64?
    public let physicalMemoryBytes: UInt64
    public let disk: DiskSpace?
    public let thermal: String
}

/// CPU is measured over successive samples for this process only, not the whole system.
public actor ResourceSampler {
    private var lastCPU: Double?
    private var lastTime: Double?

    public init() {}

    public func sample(directory: URL) -> ResourceSnapshot {
        var usage = rusage()
        let success = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = ProcessInfo.processInfo.systemUptime
        var percent: Double?
        if success {
            if let previous = lastCPU, let time = lastTime, now > time, cpu >= previous {
                percent = (cpu - previous) / (now - time) * 100
            }
            lastCPU = cpu
            lastTime = now
        } else { lastCPU = nil; lastTime = nil }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "温度略高"
        case .serious: thermal = "温度较高"
        case .critical: thermal = "温度过高"
        @unknown default: thermal = "不可用"
        }
        return ResourceSnapshot(appCPUPercent: percent, appPeakMemoryBytes: success ? UInt64(max(0, usage.ru_maxrss)) : nil,
                                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, disk: try? DiskSpace.read(at: directory), thermal: thermal)
    }
}
