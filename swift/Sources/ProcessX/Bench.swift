import Darwin
import Foundation
import SwiftUI

/// `ProcessX --bench [iterations]` — headless cost breakdown of one sampling tick.
///
/// The point is to separate the two suspects for ProcessX's own CPU footprint:
/// the syscall walk over the process table, and the SwiftUI redraw that consumes
/// its output. This half runs with no window, no timer and no view layer, so
/// whatever it reports is sampling cost and nothing else.
///
/// Reports *CPU time* (getrusage user+sys), not wall time: on a loaded machine
/// wall time mostly measures how long we waited for a core.
enum Bench {

    /// Run the measurement at the QoS the real app's main thread runs at.
    ///
    /// Without this the numbers are meaningless on Apple Silicon. A benchmark
    /// launched from a shell inherits that shell's priority, lands on efficiency
    /// cores, and bills *more* CPU-seconds for identical work — the same build
    /// measured 57 ms and 178 ms per window pass minutes apart purely on which
    /// cores it got. CPU time is only a unit of work when the core is the same.
    private static func pinToInteractiveQoS() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }

    /// Our own consumed CPU, user+system, in seconds.
    private static func cpuNow() -> Double {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return secs(ru.ru_utime) + secs(ru.ru_stime)
    }

    private static func measure(_ name: String, iterations: Int, _ body: () -> Void) {
        let c0 = cpuNow()
        let w0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { body() }
        let cpu = cpuNow() - c0
        let wall = CFAbsoluteTimeGetCurrent() - w0
        print(String(format: "  %-34s cpu %7.2f ms/iter   wall %7.2f ms/iter",
                     (name as NSString).utf8String!, cpu / Double(iterations) * 1000,
                     wall / Double(iterations) * 1000))
    }

    private static func listPIDs() -> [pid_t] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        let capacity = Int(count) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                              Int32(capacity * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func run(iterations: Int) {
        pinToInteractiveQoS()
        let pids = listPIDs()
        print("[bench] \(pids.count) processes, \(SystemStats.coreCount) cores, \(iterations) iterations each")
        print("        CPU time is what matters; wall time also counts waiting for a core.\n")

        measure("proc_listpids (whole table)", iterations: iterations) {
            _ = listPIDs()
        }

        measure("proc_pidinfo TASKALLINFO xN", iterations: iterations) {
            for pid in pids {
                var info = proc_taskallinfo()
                _ = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info,
                                 Int32(MemoryLayout<proc_taskallinfo>.size))
            }
        }

        measure("proc_pidpath xN", iterations: iterations) {
            for pid in pids {
                var buf = [CChar](repeating: 0, count: 4 * 1024)
                _ = proc_pidpath(pid, &buf, UInt32(buf.count))
            }
        }

        let sampler = Sampler()
        _ = sampler.sample()          // warm the baseline so the timed runs are representative
        measure("Sampler.sample() (full)", iterations: iterations) {
            _ = sampler.sample()
        }

        let procs = sampler.sample()
        let uid = getuid()
        measure("Grouping.build()", iterations: iterations) {
            _ = Grouping.build(procs: procs, frontPID: nil, myUID: uid)
        }

        // What the view layer asks for on every redraw, not just every tick.
        measure("visibleGroups-equivalent sort", iterations: iterations) {
            var g = Grouping.build(procs: procs, frontPID: nil, myUID: uid).groups
            g.sort { $0.cpu > $1.cpu }
            _ = g.filter { $0.cpu > 0.05 || $0.mem > 20 * 1024 * 1024 }
                 .sorted { $0.cpu < $1.cpu }
        }

        print("\n[bench] at a 2.0s tick, 1 ms/iter of sampling = 0.05% of one core.")
        exit(0)
    }

    /// `ProcessX --bench-view [iterations]` — cost of building, laying out and
    /// rasterising the whole main window once, repeatedly, against real data.
    ///
    /// A live window's CPU reading is hostage to how loaded the Mac is, whether
    /// the pointer is over the table, and whether another window is covering it —
    /// on a busy machine the same build measured 6% and 18% minutes apart. This
    /// does the same work on demand, so a view-layer change can be judged in one
    /// run instead of averaged over minutes.
    @MainActor
    static func view(iterations: Int) {
        pinToInteractiveQoS()
        let monitor = Monitor()
        monitor.tick()
        Thread.sleep(forTimeInterval: 1.0)
        monitor.tick()                          // real interval data, real row count

        let content = MainWindow(monitor: monitor).frame(width: 1180, height: 800)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        _ = renderer.nsImage                    // warm type metadata and the layout cache

        print("[bench-view] full main window, \(monitor.visibleGroups.count) visible groups")
        let c0 = cpuNow()
        let w0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            // The renderer caches aggressively; a fresh one per pass measures a
            // real build + layout + draw rather than a cache hit.
            let r = ImageRenderer(content: content)
            r.scale = 2
            _ = r.nsImage
        }
        let cpu = (cpuNow() - c0) / Double(iterations) * 1000
        let wall = (CFAbsoluteTimeGetCurrent() - w0) / Double(iterations) * 1000
        print(String(format: "  window build+layout+draw   cpu %7.1f ms   wall %7.1f ms per pass", cpu, wall))
        print(String(format: "  at one redraw per 2 s tick that is %.2f%% of one core", cpu / 20.0))
        exit(0)
    }

    /// `ProcessX --bench-live [seconds]` — the real Monitor, real 2 s timer, real
    /// sampling and grouping and publishing, for N seconds, with **no window and no
    /// view layer at all**.
    ///
    /// This is the control for the window-open measurement. Whatever the app costs
    /// with its window up, minus this, is what the view layer costs. Reported as a
    /// percentage of one core so it is directly comparable to `qa/cpucost.sh`.
    @MainActor
    static func live(seconds: Double) {
        pinToInteractiveQoS()
        let monitor = Monitor()                 // starts its own 2 s timer, exactly as the app does
        let ticks = Int((seconds / 2.0).rounded())
        print("[bench-live] Monitor only — no window, no SwiftUI. \(Int(seconds))s ≈ \(ticks) ticks.")

        let c0 = cpuNow()
        let w0 = CFAbsoluteTimeGetCurrent()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let cpu = cpuNow() - c0
        let wall = CFAbsoluteTimeGetCurrent() - w0

        // Touch the monitor so nothing above can be optimised away.
        let groups = monitor.visibleGroups.count
        print(String(format: "  model layer only          cpu %.2fs  wall %.2fs  %.2f%% of one core  (%d visible groups)",
                     cpu, wall, cpu / wall * 100, groups))
        exit(0)
    }
}
