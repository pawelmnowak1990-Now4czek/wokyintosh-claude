import Foundation
import Darwin
import MachO

struct SystemSnapshot: Codable {
    let cpu: Double
    let ram: Double
    let ssdFreeGB: Double
    let diskUsedPct: Double
    let netRate: String

    enum CodingKeys: String, CodingKey {
        case cpu, ram
        case ssdFreeGB = "ssd_free_gb"
        case diskUsedPct = "disk_used_pct"
        case netRate = "net_rate"
    }
}

final class SystemMonitor {
    private var previousCPUTicks: [natural_t]?
    private var previousNetworkBytes: UInt64?
    private var previousNetworkTime: TimeInterval?

    func snapshot() -> SystemSnapshot {
        let disk = diskStats()
        return SystemSnapshot(
            cpu: cpuUsage(),
            ram: memoryUsage(),
            ssdFreeGB: disk.freeGB,
            diskUsedPct: disk.usedPct,
            netRate: networkRate()
        )
    }

    /// Procent zajętości CPU z dwóch odczytów liczników jądra.
    /// Kolejność wartości: [user, system, idle, nice] (jak CPU_STATE_*).
    /// Odejmowanie zawijające (&-) daje poprawny wynik również wtedy,
    /// gdy 32-bitowy licznik przekręci się (po ok. 50 dniach pracy).
    static func cpuPercent(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }

        let user = UInt64(current[Int(CPU_STATE_USER)] &- previous[Int(CPU_STATE_USER)])
        let system = UInt64(current[Int(CPU_STATE_SYSTEM)] &- previous[Int(CPU_STATE_SYSTEM)])
        let idle = UInt64(current[Int(CPU_STATE_IDLE)] &- previous[Int(CPU_STATE_IDLE)])
        let nice = UInt64(current[Int(CPU_STATE_NICE)] &- previous[Int(CPU_STATE_NICE)])

        let total = Double(user + system + idle + nice)
        guard total > 0 else { return 0 }

        return max(0, min(100, Double(user + system + nice) / total * 100))
    }

    /// Procent zajętej pamięci liczony tak, jak "Użyta pamięć" w Monitorze aktywności:
    /// pamięć aplikacji (internal bez purgeable) + wired + skompresowana.
    /// Stron `inactive` i `active` nie wliczamy, bo to głównie cache plików,
    /// który system oddaje od ręki.
    static func memoryPercent(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64
    ) -> Double {
        guard totalBytes > 0 else { return 0 }

        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let used = (appPages + wiredPages + compressorPages) * pageSize

        return max(0, min(100, Double(used) / Double(totalBytes) * 100))
    }

    private func cpuUsage() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let current: [natural_t] = [
            info.cpu_ticks.0,
            info.cpu_ticks.1,
            info.cpu_ticks.2,
            info.cpu_ticks.3
        ]

        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return 0 }

        return SystemMonitor.cpuPercent(previous: previous, current: current)
    }

    private func memoryUsage() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result: kern_return_t = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        return SystemMonitor.memoryPercent(
            internalPages: UInt64(vmStats.internal_page_count),
            purgeablePages: UInt64(vmStats.purgeable_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressorPages: UInt64(vmStats.compressor_page_count),
            pageSize: UInt64(vm_kernel_page_size),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private func diskStats() -> (freeGB: Double, usedPct: Double) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            let used = max(0, total - free)
            return (
                free / 1_073_741_824,
                total > 0 ? used / total * 100 : 0
            )
        } catch {
            return (0, 0)
        }
    }

    private func networkBytes() -> UInt64 {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return 0 }
        defer { freeifaddrs(first) }

        var total: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = start

        while let current = pointer {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)

            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                total += UInt64(data.pointee.ifi_ibytes)
                total += UInt64(data.pointee.ifi_obytes)
            }

            pointer = interface.ifa_next
        }

        return total
    }

    private func networkRate() -> String {
        let now = Date().timeIntervalSince1970
        let bytes = networkBytes()

        defer {
            previousNetworkBytes = bytes
            previousNetworkTime = now
        }

        guard let previousBytes = previousNetworkBytes,
              let previousTime = previousNetworkTime else {
            return "0 KB/s"
        }

        let delta = bytes >= previousBytes ? bytes - previousBytes : 0
        let elapsed = max(0.25, now - previousTime)
        let rate = Double(delta) / elapsed

        if rate >= 1_048_576 {
            return String(format: "%.1f MB/s", rate / 1_048_576)
        }
        return String(format: "%.0f KB/s", rate / 1024)
    }
}
