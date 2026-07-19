import Darwin
import Foundation

/// `ProcessX --selftest` — exercises the real syscall stack headlessly:
/// libproc sampling, the grouping heuristics, the media guard, and an actual
/// throttle/restore round-trip against a process we spawn ourselves.
enum SelfTest {
    private nonisolated(unsafe) static var failures = 0

    private static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        print("  \(cond ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !cond { failures += 1 }
    }

    @MainActor
    static func run() {
        print("ProcessX self-test\n")

        print("[media guard] helper binaries inside protected bundles")
        let mediaCases: [(String, Bool)] = [
            ("/Applications/zoom.us.app/Contents/MacOS/zoom.us", true),
            ("/Applications/zoom.us.app/Contents/Frameworks/aomhost.app/Contents/MacOS/aomhost", true),
            ("/Applications/Microsoft Teams.app/Contents/Frameworks/x.app/Contents/MacOS/modulehost", true),
            ("/Applications/Spotify.app/Contents/MacOS/Spotify", true),
            ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", false),
            ("/opt/homebrew/bin/ffmpeg", false),
            ("/Applications/zoominfo-tool.app/Contents/MacOS/zoominfo", false),
        ]
        for (path, expected) in mediaCases {
            check("\(expected ? "protected" : "tamable "): \((path as NSString).lastPathComponent)",
                  Policy.matches(Policy.mediaSafe, path) == expected)
        }

        print("\n[grouping] terminal-hosted CLI vs background hog")
        let procs = [
            ProcSample(pid: 700, ppid: 1, uid: 501, name: "iTerm2",
                       path: "/Applications/iTerm2.app/Contents/MacOS/iTerm2",
                       rss: 100_000_000, priority: 26, cpuPct: 2),
            ProcSample(pid: 701, ppid: 700, uid: 501, name: "login", path: "/usr/bin/login",
                       rss: 1_000_000, priority: 26, cpuPct: 0),
            ProcSample(pid: 702, ppid: 701, uid: 501, name: "zsh", path: "/bin/-zsh",
                       rss: 1_000_000, priority: 26, cpuPct: 0),
            ProcSample(pid: 703, ppid: 702, uid: 501, name: "node", path: "/opt/homebrew/bin/node",
                       rss: 500_000_000, priority: 26, cpuPct: 90),
            ProcSample(pid: 800, ppid: 1, uid: 501, name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg",
                       rss: 200_000_000, priority: 26, cpuPct: 95),
        ]
        let model = Grouping.build(procs: procs, frontPID: 700, myUID: 501)  // terminal frontmost
        let cliKey = model.byPID[703]?.groupKey ?? ""
        let ffKey = model.byPID[800]?.groupKey ?? ""
        let cliGroup = model.group(for: cliKey)
        check("CLI session gets its own group", cliGroup?.kind == .cli, "key=\(cliKey)")
        check("CLI's parentKey is its host terminal", cliGroup?.parentKey == "a:iTerm2",
              "parentKey=\(cliGroup?.parentKey ?? "nil")")
        check("frontKey is the terminal app", model.frontKey == "a:iTerm2", "front=\(model.frontKey ?? "nil")")
        check("CLI in frontmost terminal counts as FRONT (never tamed)", model.isFront(cliKey))
        check("background ffmpeg does NOT count as front (tamable)", !model.isFront(ffKey))

        print("\n[sampler] libproc — no subprocesses")
        let sampler = Sampler()
        _ = sampler.sample()                       // establish CPU baseline
        Thread.sleep(forTimeInterval: 0.6)
        let live = sampler.sample()
        check("enumerated the process table", live.count > 20, "\(live.count) processes")
        check("paths resolve", live.contains { $0.path.hasPrefix("/") })
        check("priorities read back", live.contains { $0.priority > 0 })
        let busiest = live.max { $0.cpuPct < $1.cpuPct }
        check("interval CPU computed", live.contains { $0.cpuPct > 0 },
              "busiest: \(busiest.map { "\($0.name) \(String(format: "%.1f", $0.cpuPct))%" } ?? "none")")

        print("\n[throttle] real setpriority round-trip on our own child")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            let pid = child.processIdentifier
            Thread.sleep(forTimeInterval: 0.8)

            func priority(_ pid: pid_t) -> Int32 {
                var t = proc_taskinfo()
                let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
                return n > 0 ? t.pti_priority : -1
            }

            // CPU accuracy: `yes` spins one core flat out, so a correct sampler must
            // read ~100%. This is the guard against the mach-ticks-vs-nanoseconds
            // bug, which silently under-reports by 41x on Apple Silicon and not at
            // all on Intel. "> 0" would have passed while being 41x wrong.
            let cpuSampler = Sampler()
            _ = cpuSampler.sample()
            Thread.sleep(forTimeInterval: 1.5)
            let measured = cpuSampler.sample().first { $0.pid == pid }?.cpuPct ?? 0
            check("busy child reads ~100% of a core (not 41x off)",
                  measured > 80 && measured < 130, String(format: "measured %.1f%%", measured))

            let before = priority(pid)
            check("child starts at normal priority", before > Sampler.bgBand, "priority=\(before)")

            check("setBackground(true) succeeds", Throttle.setBackground(pid, true))
            Thread.sleep(forTimeInterval: 0.4)
            let during = priority(pid)
            check("kernel reports it in the background band", during <= Sampler.bgBand, "priority=\(during)")

            check("setBackground(false) succeeds", Throttle.setBackground(pid, false))
            Thread.sleep(forTimeInterval: 0.4)
            let after = priority(pid)
            check("kernel reports it restored", after > Sampler.bgBand, "priority=\(after)")

            child.terminate()
        } catch {
            check("spawn test child", false, "\(error)")
        }

        print("\n[monitor] the real button-click path: policy gate + store + kernel")
        MainActor.assumeIsolated {
            let m = Monitor()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            do {
                try child.run()
                let pid = child.processIdentifier
                Thread.sleep(forTimeInterval: 0.8)
                m.tick()   // burner must be in the model before we can act on it

                func priority(_ pid: pid_t) -> Int32 {
                    var t = proc_taskinfo()
                    let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
                    return n > 0 ? t.pti_priority : -1
                }

                let change = m.throttle(pids: [pid], origin: .manual, manual: true)
                check("Monitor.throttle applies to the target", change.pids == [pid])
                check("store attributes it to us", m.isThrottledByUs(pid))
                check("origin recorded", m.origin(pid) == .manual)
                Thread.sleep(forTimeInterval: 0.5)
                check("kernel really moved it to the band", priority(pid) <= Sampler.bgBand,
                      "priority=\(priority(pid))")

                m.restore(pids: [pid])
                check("record cleared after restore", !m.isThrottledByUs(pid))
                Thread.sleep(forTimeInterval: 0.4)
                check("kernel really restored it", priority(pid) > Sampler.bgBand,
                      "priority=\(priority(pid))")

                // The guard that matters most: never throttle ourselves.
                let selfChange = m.throttle(pids: [getpid()], origin: .manual, manual: true)
                check("refuses to throttle ProcessX itself", selfChange.pids.isEmpty)

                child.terminate()
            } catch {
                check("monitor path", false, "\(error)")
            }
        }

        print("\n[system] memory / GPU / frontmost via system APIs")
        let mem = SystemStats.memory()
        check("physical memory read", mem.total > 0, "\(mem.total / 1_073_741_824) GB")
        check("used memory plausible", mem.used > 0 && mem.used < mem.total,
              "\(mem.used / 1_048_576) MB used, pressure=\(mem.pressure)")
        let gpu = SystemStats.gpuUtilization()
        check("GPU utilization via IOKit", gpu != nil, gpu.map { "\($0)%" } ?? "unavailable")

        print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        exit(failures == 0 ? 0 : 1)
    }
}
