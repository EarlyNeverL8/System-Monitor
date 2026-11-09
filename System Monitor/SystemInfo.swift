import Foundation
import Darwin
import IOKit

// MARK: - Live readings
/// One snapshot of the values shown in the menu bar and dashboard.
nonisolated struct SystemInfo: Sendable {
    var cpuUsage: Double?                     // percent across all cores
    var memoryUsage: UInt64?                  // bytes
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskSpaceAvailable: UInt64?           // bytes, as Finder reports it (includes purgeable)
    var diskSpaceTotal: UInt64?
    var downloadRate: Double?                 // bytes per second
    var uploadRate: Double?
    var gpuUsage: Double?                     // percent
    var coreUsage: [Double] = []              // percent per CPU core
    var memoryPressure: MemoryPressure?
    var swapUsed: UInt64?                     // bytes
    var diskReadRate: Double?                 // bytes per second, all internal + external disks
    var diskWriteRate: Double?
}

/// The kernel's memory pressure level, as shown in Activity Monitor's Memory tab.
nonisolated enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

// MARK: - Hardware description
/// Static chip details (read once): "Apple M4 Pro", core counts and GPU cores.
nonisolated struct HardwareInfo: Sendable {
    let chip: String
    let totalCores: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int?

    static let current = HardwareInfo()

    init() {
        chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown processor"
        totalCores = Self.sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        // perflevel0 = performance cores, perflevel1 = efficiency cores (Apple silicon only).
        performanceCores = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? totalCores
        efficiencyCores = Self.sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        gpuCores = Self.gpuCoreCount()
    }

    /// "M4 Pro" rather than "Apple M4 Pro".
    var chipName: String { chip.replacingOccurrences(of: "Apple ", with: "") }

    /// "12-core CPU (8P + 4E) · 16-core GPU"
    var coreSummary: String {
        var parts = [efficiencyCores > 0
            ? "\(totalCores)-core CPU (\(performanceCores)P + \(efficiencyCores)E)"
            : "\(totalCores)-core CPU"]
        if let gpuCores { parts.append("\(gpuCores)-core GPU") }
        return parts.joined(separator: " · ")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// Apple GPUs publish their core count on the AGXAccelerator IOKit service.
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}

// MARK: - Formatting
nonisolated enum Format {
    /// Finder-style decimal sizes: "260 GB", "45.3 GB", "1.2 TB".
    static func storage(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let gigabytes = Double(bytes) / 1e9
        if gigabytes >= 1000 { return (gigabytes / 1000).formatted(.number.precision(.fractionLength(0...1))) + " TB" }
        let digits = gigabytes >= 100 ? 0 : 1
        return gigabytes.formatted(.number.precision(.fractionLength(0...digits))) + " GB"
    }

    /// "260 GB of 500 GB available"
    static func storageSummary(available: UInt64?, total: UInt64?) -> String {
        guard let available else { return "—" }
        guard let total else { return "\(storage(available)) available" }
        return "\(storage(available)) of \(storage(total)) available"
    }

    /// CPU load such as "12.3 %".
    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f %%", $0) } ?? "—"
    }

    /// File sizes as Finder shows them: "1.2 GB".
    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// Live throughput such as "1.4 MB/s".
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    static func megabits(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 1)))
    }
}

// MARK: - CPU ticks
nonisolated struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    /// Busy share of the interval since `previous`, as a percentage.
    func usage(since previous: CPUTicks) -> Double? {
        // Mach counters wrap at UInt32.max; subtract before widening.
        let busy = UInt64(user &- previous.user)
            + UInt64(system &- previous.system)
            + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

// MARK: - Network byte counters
/// Total bytes received/sent by physical interfaces (Wi-Fi, Ethernet, cellular).
nonisolated struct NetworkCounters: Sendable {
    var received: UInt64 = 0
    var sent: UInt64 = 0

    /// Reads 64-bit interface counters via NET_RT_IFLIST2 (getifaddrs only has 32-bit
    /// counters, which wrap every 4 GB). VPN/bridge interfaces are skipped so traffic
    /// isn't counted twice.
    static func read() -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var totals = NetworkCounters()
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let isUp = message.ifm_flags & IFF_UP != 0 && message.ifm_flags & IFF_LOOPBACK == 0
                    if isUp, if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if interface.hasPrefix("en") || interface.hasPrefix("pdp_ip") {
                            totals.received &+= message.ifm_data.ifi_ibytes
                            totals.sent &+= message.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return totals
    }
}

// MARK: - Disk byte counters
/// Total bytes read/written by all block storage drivers since boot.
nonisolated struct DiskCounters: Sendable {
    var read: UInt64 = 0
    var written: UInt64 = 0

    static func read() -> DiskCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var totals = DiskCounters()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            totals.read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            totals.written &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return totals
    }
}

// MARK: - Sampler
/// Collects one SystemInfo snapshot. Runs on its own actor so mach/sysctl/disk
/// calls never block the UI thread.
actor SystemSampler {
    private var sampler = SystemInfoSampler()
    func sample() -> SystemInfo { sampler.sample() }
}

nonisolated struct SystemInfoSampler {
    private var previousTicks: CPUTicks?
    private var previousCoreTicks: [CPUTicks] = []
    private var previousNetwork: (counters: NetworkCounters, time: UInt64)?
    private var previousDisk: (counters: DiskCounters, time: UInt64)?
    private var disk: (available: UInt64?, total: UInt64?) = (nil, nil)
    private var samplesSinceDisk = 10            // 10 forces a disk read on the first sample

    mutating func sample() -> SystemInfo {
        var info = SystemInfo()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        // CPU: usage is the change in tick counters since the previous sample.
        var cpu = host_cpu_load_info()
        let cpuCapacity = MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        var cpuCount = mach_msg_type_number_t(cpuCapacity)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: cpuCapacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = CPUTicks(user: cpu.cpu_ticks.0, system: cpu.cpu_ticks.1,
                                 idle: cpu.cpu_ticks.2, nice: cpu.cpu_ticks.3)
            if let previousTicks { info.cpuUsage = ticks.usage(since: previousTicks) }
            previousTicks = ticks
        } else {
            previousTicks = nil
        }

        // Memory: app + wired + compressed pages, like Activity Monitor's "Memory Used".
        var vm = vm_statistics64()
        let vmCapacity = MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        var vmCount = mach_msg_type_number_t(vmCapacity)
        var pageSize: vm_size_t = 0
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS {
            info.memoryUsage = Self.usedMemory(vm, pageSize: UInt64(pageSize))
        }

        // Disk: free space changes slowly and is costly to compute, so read every 10th sample.
        if samplesSinceDisk >= 10 {
            samplesSinceDisk = 0
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                             .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacityForImportantUsage
                    ?? values.volumeAvailableCapacity.map(Int64.init)
                disk.available = available.flatMap { $0 >= 0 ? UInt64($0) : nil }
                disk.total = values.volumeTotalCapacity.flatMap { $0 > 0 ? UInt64($0) : nil }
            }
        }
        samplesSinceDisk += 1
        info.diskSpaceAvailable = disk.available
        info.diskSpaceTotal = disk.total

        // Network: bytes transferred since the previous sample, divided by elapsed time.
        let now = DispatchTime.now().uptimeNanoseconds
        if let counters = NetworkCounters.read() {
            if let previous = previousNetwork, now > previous.time,
               counters.received >= previous.counters.received, counters.sent >= previous.counters.sent {
                let seconds = Double(now - previous.time) / 1e9
                info.downloadRate = Double(counters.received - previous.counters.received) / seconds
                info.uploadRate = Double(counters.sent - previous.counters.sent) / seconds
            }
            previousNetwork = (counters, now)
        }

        // Disk throughput: bytes read/written since the previous sample.
        if let counters = DiskCounters.read() {
            if let previous = previousDisk, now > previous.time,
               counters.read >= previous.counters.read, counters.written >= previous.counters.written {
                let seconds = Double(now - previous.time) / 1e9
                info.diskReadRate = Double(counters.read - previous.counters.read) / seconds
                info.diskWriteRate = Double(counters.written - previous.counters.written) / seconds
            }
            previousDisk = (counters, now)
        }

        let cores = Self.coreTicks(host: host)
        if cores.count == previousCoreTicks.count {
            info.coreUsage = zip(cores, previousCoreTicks).map { $0.usage(since: $1) ?? 0 }
        }
        previousCoreTicks = cores

        info.gpuUsage = Self.gpuUtilization()
        info.memoryPressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressure.init(rawValue:))
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { info.swapUsed = swap.xsu_used }
        return info
    }

    /// Tick counters for each CPU core.
    private static func coreTicks(host: mach_port_t) -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * states
            return CPUTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }

    /// GPU busy percentage reported by the graphics driver (no special permissions needed).
    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var highest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int else { continue }
            highest = max(highest ?? 0, Double(utilization))
        }
        return highest
    }

    private static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    static func usedMemory(_ vm: vm_statistics64, pageSize: UInt64) -> UInt64 {
        // Exclude reclaimable purgeable pages and file cache. Count compressed
        // memory by its physical footprint, not the uncompressed page count.
        let appPages = UInt64(vm.internal_page_count) - min(
            UInt64(vm.internal_page_count), UInt64(vm.purgeable_count)
        )
        return (appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize
    }
}
