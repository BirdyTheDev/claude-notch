import Darwin
import Foundation
import IOKit.ps

struct SystemSnapshot: Equatable {
    var cpu: Double = 0            // 0…1
    var cpuPerCore: [Double] = []
    var memoryUsed: Double = 0     // bytes
    var memoryTotal: Double = 1
    var diskUsed: Double = 0
    var diskTotal: Double = 1
    var netDown: Double = 0        // bytes/sec
    var netUp: Double = 0
    var uptime: TimeInterval = 0

    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    var diskFraction: Double { diskTotal > 0 ? diskUsed / diskTotal : 0 }
}

struct BatterySnapshot: Equatable {
    var percent: Int = 100
    var charging = false
    var pluggedIn = false
    var minutesRemaining: Int?
    var health: Int?
    var cycles: Int?
    var present = true

    var symbol: String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Polls CPU/memory/disk/network. All work happens off the main thread.
final class SystemMonitor: @unchecked Sendable {
    private var previousCPU: [UInt32] = []
    private var previousNet: (down: UInt64, up: UInt64, time: CFTimeInterval)?

    func read() -> SystemSnapshot {
        var snap = SystemSnapshot()
        (snap.cpu, snap.cpuPerCore) = cpuUsage()
        (snap.memoryUsed, snap.memoryTotal) = memory()
        (snap.diskUsed, snap.diskTotal) = disk()
        (snap.netDown, snap.netUp) = network()
        snap.uptime = ProcessInfo.processInfo.systemUptime
        return snap
    }

    private func cpuUsage() -> (Double, [Double]) {
        var count = mach_msg_type_number_t()
        var cpuCount = natural_t()
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }

        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { previousCPU = ticks }
        guard previousCPU.count == ticks.count else { return (0, []) }

        var perCore: [Double] = []
        let states = Int(CPU_STATE_MAX)
        for core in 0..<Int(cpuCount) {
            let base = core * states
            var busy = 0.0, total = 0.0
            for state in 0..<states {
                let delta = Double(ticks[base + state] &- previousCPU[base + state])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
            perCore.append(total > 0 ? busy / total : 0)
        }
        let average = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return (average, perCore)
    }

    private func memory() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = Double(vm_kernel_page_size)
        // "Used" the way Activity Monitor counts it: app memory + wired + compressed.
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (used, total)
    }

    private func disk() -> (Double, Double) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity else { return (0, 1) }
        let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (Double(total) - free, Double(total))
    }

    private func network() -> (Double, Double) {
        var down: UInt64 = 0, up: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            if let data = current.pointee.ifa_data, current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                down += UInt64(stats.ifi_ibytes)
                up += UInt64(stats.ifi_obytes)
            }
            pointer = current.pointee.ifa_next
        }
        let now = CACurrentMediaTimeCompat()
        defer { previousNet = (down, up, now) }
        guard let previous = previousNet, now > previous.time else { return (0, 0) }
        let elapsed = now - previous.time
        return (Double(down &- previous.down) / elapsed, Double(up &- previous.up) / elapsed)
    }

    private func CACurrentMediaTimeCompat() -> CFTimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

enum BatteryReader {
    static func read() -> BatterySnapshot {
        var snap = BatterySnapshot()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        else {
            snap.present = false
            return snap
        }

        let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = info[kIOPSMaxCapacityKey] as? Int ?? 100
        snap.percent = max > 0 ? Int((Double(current) / Double(max)) * 100) : current
        snap.charging = info[kIOPSIsChargingKey] as? Bool ?? false
        snap.pluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let remaining = snap.charging
            ? info[kIOPSTimeToFullChargeKey] as? Int
            : info[kIOPSTimeToEmptyKey] as? Int
        if let remaining, remaining > 0 { snap.minutesRemaining = remaining }

        // Health and cycle count come from IOKit's battery service, not the power-source blob.
        if let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) as io_service_t?,
           service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue
            }
            snap.cycles = number("CycleCount")
            if let design = number("DesignCapacity"), let now = number("AppleRawMaxCapacity"), design > 0 {
                snap.health = Int((Double(now) / Double(design)) * 100)
            }
        }
        return snap
    }
}

enum Bytes {
    static func short(_ value: Double) -> String {
        switch value {
        case ..<1_024: return String(format: "%.0fB", value)
        case ..<1_048_576: return String(format: "%.0fK", value / 1_024)
        case ..<1_073_741_824: return String(format: "%.1fM", value / 1_048_576)
        default: return String(format: "%.1fG", value / 1_073_741_824)
        }
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1fGB", value / 1_073_741_824)
    }
}
