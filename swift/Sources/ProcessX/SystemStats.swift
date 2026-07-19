import AppKit
import Darwin
import Foundation
import IOKit

struct MemoryStats {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var pressure: String = "normal"   // normal | warning | critical
    var swapUsed: UInt64 = 0
}

/// Memory, GPU and frontmost-app readings — all via system APIs.
enum SystemStats {

    static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// host_statistics64 instead of parsing `vm_stat` output.
    static func memory() -> MemoryStats {
        var s = MemoryStats()
        s.total = ProcessInfo.processInfo.physicalMemory

        var vmStat = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // "Used" the way Activity Monitor means it: what can't be reclaimed cheaply.
            s.used = (UInt64(vmStat.active_count) + UInt64(vmStat.wire_count)
                      + UInt64(vmStat.compressor_page_count)) * page
        }

        s.pressure = pressureLevel(usedRatio: s.total > 0 ? Double(s.used) / Double(s.total) : 0)
        s.swapUsed = swapUsage()
        return s
    }

    private static func pressureLevel(usedRatio: Double) -> String {
        // The kernel's own view first; fall back to a ratio if unavailable.
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            switch level {
            case 4: return "critical"
            case 2: return "warning"
            case 1: return "normal"
            default: break
            }
        }
        if usedRatio > 0.94 { return "critical" }
        if usedRatio > 0.86 { return "warning" }
        return "normal"
    }

    private static func swapUsage() -> UInt64 {
        var xsu = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsu, &size, nil, 0) == 0 else { return 0 }
        return xsu.xsu_used
    }

    /// GPU utilization straight from the IORegistry — no `ioreg` subprocess, no
    /// regex over its text. Still device-wide: macOS exposes no per-process GPU
    /// share without admin rights, in Swift or otherwise.
    static func gpuUtilization() -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any],
                  let util = stats["Device Utilization %"] as? Int else { continue }
            best = max(best ?? 0, util)
        }
        return best
    }

    /// NSWorkspace instead of two `lsappinfo` subprocesses.
    static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
