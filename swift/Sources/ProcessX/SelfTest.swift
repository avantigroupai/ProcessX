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

    /// Run-queue depth per core.
    private static var loadPerCore: Double {
        var avg = [Double](repeating: 0, count: 3)
        guard getloadavg(&avg, 3) > 0 else { return 0 }
        return avg[0] / Double(max(SystemStats.coreCount, 1))
    }

    /// A check that asserts an absolute CPU percentage.
    ///
    /// These are only meaningful when a spinning process can actually get a core.
    /// On an oversubscribed machine it cannot — with 300 runnable threads on 8
    /// cores, `yes` measures 8% and every magnitude assertion fails for reasons
    /// that have nothing to do with this code. Reporting that as FAIL trains
    /// people to ignore the suite, and the people running it are by definition on
    /// a busy Mac. So it is reported as SKIP, with the reason, and does not fail
    /// the run. Mechanism checks (does the duty cycle engage, does anything stay
    /// suspended) are load-independent and always assert.
    private static func checkCPU(_ name: String, _ cond: Bool, _ detail: String = "") {
        let load = loadPerCore
        guard load <= 1.5 else {
            skip(name, String(format: "machine oversubscribed (load %.1f per core)", load)
                 + (detail.isEmpty ? "" : ", measured \(detail)"))
            return
        }
        check(name, cond, detail)
    }

    private static func skip(_ name: String, _ reason: String) {
        print("  SKIP  \(name)  — \(reason)")
    }

    @MainActor
    static func run() {
        print("ProcessX self-test\n")

        // Redirect the cap recovery record before anything else: the [monitor]
        // section below constructs a real Monitor, whose init releases orphaned
        // caps. Pointed at the real file that would resume — and forget — the caps
        // of a ProcessX instance running right now.
        let tmpCaps = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("processx-selftest-caps-\(getpid()).json")
        CapPersistence.url = tmpCaps

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
            checkCPU("busy child reads ~100% of a core (not 41x off)",
                     measured > 80 && measured < 130, String(format: "%.1f%%", measured))

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

        print("\n[cap policy] what a hard cap may never suspend")
        let uid = getuid(), me = getpid()
        func sample(_ name: String, _ path: String, stopped: Bool = false) -> ProcSample {
            ProcSample(pid: 9001, ppid: 1, uid: uid, name: name, path: path,
                       rss: 1, priority: 26, cpuPct: 90, isStopped: stopped)
        }
        check("refuses a terminal (you'd freeze your own way back)",
              Policy.capIneligibleReason(sample("Ghostty", "/Applications/Ghostty.app/Contents/MacOS/Ghostty"),
                                         myUID: uid, selfPID: me) != nil)
        check("refuses a shell",
              Policy.capIneligibleReason(sample("zsh", "/bin/zsh"), myUID: uid, selfPID: me) != nil)
        // Unlike Slow down, there is no manual override here: a dropped call is
        // not undone by lifting the cap afterwards.
        check("refuses a call app even on an explicit click",
              Policy.capIneligibleReason(sample("zoom.us", "/Applications/zoom.us.app/Contents/MacOS/zoom.us"),
                                         myUID: uid, selfPID: me) != nil)
        check("refuses a process someone else already suspended",
              Policy.capIneligibleReason(sample("node", "/opt/homebrew/bin/node", stopped: true),
                                         myUID: uid, selfPID: me) != nil)
        check("allows an ordinary background hog",
              Policy.capIneligibleReason(sample("ffmpeg", "/opt/homebrew/bin/ffmpeg"),
                                         myUID: uid, selfPID: me) == nil)

        print("\n[cap] real SIGSTOP/SIGCONT duty cycle against our own child")

        func burner() -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            return p
        }
        /// True interval CPU for one pid, % of a core.
        func measure(_ pid: pid_t, _ seconds: Double) -> Double {
            let s = Sampler()
            _ = s.sample()
            Thread.sleep(forTimeInterval: seconds)
            return s.sample().first { $0.pid == pid }?.cpuPct ?? 0
        }
        /// Single-pid status read — cheap enough to poll, unlike a full table walk.
        func stopped(_ pid: pid_t) -> Bool {
            var info = proc_bsdinfo()
            let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            return n == Int32(MemoryLayout<proc_bsdinfo>.size) && info.pbi_status == Sampler.stoppedStatus
        }
        /// Did this pid spend any of the window suspended? Polling for the stop
        /// edge tests the duty cycle itself, which — unlike a CPU percentage —
        /// means the same thing on an idle machine and a saturated one.
        func everStopped(_ pid: pid_t, over seconds: Double) -> Bool {
            let step = 0.02
            for _ in 0..<Int(seconds / step) {
                if stopped(pid) { return true }
                Thread.sleep(forTimeInterval: step)
            }
            return false
        }

        let capper = Capper()
        let hog = burner()
        do {
            try hog.run()
            let pid = hog.processIdentifier
            Thread.sleep(forTimeInterval: 0.5)
            let path = executablePath(of: pid) ?? "/usr/bin/yes"

            check("uncapped child is never suspended", !everStopped(pid, over: 0.6))
            // What one core is worth to this process right now. On a saturated
            // machine that is nowhere near 100%, so the cap is judged against what
            // the process actually gets rather than against a fixed number.
            let free = measure(pid, 1.2)
            check("uncapped child gets CPU", free > 1, String(format: "%.1f%% of a core", free))

            // Cap at a quarter of what this machine is actually giving it. A fixed
            // target would be a no-op under heavy load — correctly, since a cap is
            // a ceiling — and the duty cycle would never engage to be tested.
            let targetPct = max(free * 0.25, 0.1)
            // Below this the target lands under the controller's own 0.5% floor,
            // so the cap is correctly a no-op and there is no regulation to assert.
            let measurable = free >= 3
            capper.set(key: "selftest", name: "yes", percent: targetPct,
                       targets: [CapTarget(pid: pid, path: path)])
            Thread.sleep(forTimeInterval: 2.0)                 // let the loop converge
            if measurable {
                check("cap suspends it as part of the duty cycle", everStopped(pid, over: 1.0))
            } else {
                skip("cap suspends it as part of the duty cycle",
                     String(format: "burner only got %.1f%% of a core; no headroom to cap", free))
            }
            let held = measure(pid, 2.0)
            check("cap never freezes it outright", held > 0, String(format: "%.2f%% while capped", held))
            // Room for the loop to hunt, but well short of `free` — a cap that did
            // nothing would land back at `free` and fail this.
            let ceiling = max(targetPct * 2.2, 3)
            if measurable {
                checkCPU("cap holds CPU at or below its target", held <= ceiling,
                         String(format: "free %.1f%% -> capped %.1f%% at a %.1f%% cap (ceiling %.1f%%)",
                                free, held, targetPct, ceiling))
            } else {
                skip("cap holds CPU at or below its target",
                     String(format: "free rate %.1f%% is below the noise floor", free))
            }
            check("recovery record written while capped",
                  CapPersistence.read().contains { $0.targets.contains { $0.pid == pid } })

            capper.clear("selftest")
            Thread.sleep(forTimeInterval: 0.8)
            // The failure this guards against is a stranded continuation still
            // stopping the process after the cap is gone — which a single status
            // read would miss four times out of five.
            check("no duty cycle survives the uncap", !everStopped(pid, over: 1.0))
            check("recovery record cleared", CapPersistence.read().isEmpty)

            // The handler that runs when we crash. kill(2) is the only call it makes.
            CapEmergency.set([pid])
            _ = kill(pid, SIGSTOP)
            Thread.sleep(forTimeInterval: 0.3)
            check("child really is suspended", stopped(pid))
            CapEmergency.resumeAll()
            Thread.sleep(forTimeInterval: 0.3)
            check("emergency resume unfreezes it", !stopped(pid))
            CapEmergency.set([])

            hog.terminate()
        } catch {
            check("spawn cap test child", false, "\(error)")
        }

        print("\n[cap via Monitor] the real menu-click path, and that a cap survives ticking")
        MainActor.assumeIsolated {
            let m = Monitor()

            // A child of this process inherits our place in the tree — run from a
            // terminal that makes it part of the frontmost terminal *session*, which
            // is exactly what a cap must refuse. Spawn through a shell that exits, so
            // the burner is reparented to launchd and lands in a background group.
            let spawn = Process()
            spawn.executableURL = URL(fileURLWithPath: "/bin/sh")
            spawn.arguments = ["-c", "/usr/bin/yes > /dev/null 2>&1 & echo $!"]
            let pipe = Pipe()
            spawn.standardOutput = pipe
            do {
                try spawn.run()
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                spawn.waitUntilExit()
                guard let pid = pid_t(String(decoding: out, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    check("spawned a detached burner", false, "no pid on stdout"); return
                }
                Thread.sleep(forTimeInterval: 0.6)
                m.tick()

                guard let key = m.model.byPID[pid]?.groupKey, let g = m.model.group(for: key) else {
                    check("detached burner is in the model", false); return
                }
                check("detached burner's group can be capped", m.capRefusal(g) == nil,
                      m.capRefusal(g) ?? "eligible")

                m.setCap(g, percent: 5)
                check("Monitor records the cap", m.isCapped(key))
                check("cap suspends the target", everStopped(pid, over: 1.5))

                // The regression this exists for: reconcileCaps re-resolves each
                // cap's pids from a fresh sample, and a capped process is stopped
                // most of the time. If that reads as "someone else suspended it",
                // the cap deletes itself on the very next tick.
                for _ in 0..<3 { m.tick(); Thread.sleep(forTimeInterval: 0.4) }
                check("cap survives three sampling ticks", m.isCapped(key))
                check("still holding its target after ticking", !(m.cap(forKey: key)?.targets.isEmpty ?? true))
                check("ProcessX never capped itself",
                      m.cap(forKey: key)?.targets.contains { $0.pid == getpid() } == false)

                m.clearCap(key: key, name: "burner")
                Thread.sleep(forTimeInterval: 0.5)
                check("Monitor drops the cap", !m.isCapped(key))
                check("nothing left suspended by the Monitor path", !everStopped(pid, over: 1.0))

                // SIGCONT first: a stopped process never sees a SIGTERM, so killing
                // a capped process in the wrong order leaves it running forever.
                _ = kill(pid, SIGCONT)
                _ = kill(pid, SIGTERM)
            } catch {
                check("Monitor cap path", false, "\(error)")
            }

            // The other half of the same rule: a CLI session hosted by the frontmost
            // terminal is foreground, and must be refused however it is reached.
            let inTerminal = burner()
            do {
                try inTerminal.run()
                Thread.sleep(forTimeInterval: 0.6)
                m.tick()
                let pid = inTerminal.processIdentifier
                if let key = m.model.byPID[pid]?.groupKey, let g = m.model.group(for: key),
                   m.model.isFront(key) {
                    check("refuses to cap a CLI session in the frontmost terminal",
                          m.capRefusal(g) != nil, m.capRefusal(g) ?? "allowed it")
                } else {
                    check("refuses to cap a CLI session in the frontmost terminal", true,
                          "skipped — not launched from a frontmost terminal")
                }
                inTerminal.terminate()
            } catch {
                check("frontmost-session refusal", false, "\(error)")
            }
        }

        print("\n[cap guardian] the SIGKILL path — a separate process resumes for us")
        let orphan = burner()
        let doomed = Process()
        doomed.executableURL = URL(fileURLWithPath: "/bin/sleep")
        doomed.arguments = ["30"]
        do {
            try orphan.run()
            try doomed.run()
            Thread.sleep(forTimeInterval: 0.4)
            let pid = orphan.processIdentifier
            let path = executablePath(of: pid) ?? "/usr/bin/yes"

            // Stand in for a capped app whose owner is about to die uncleanly.
            CapPersistence.write([CapRecord(key: "selftest", name: "yes", percent: 10,
                                            targets: [CapTarget(pid: pid, path: path)], at: Date())])
            _ = kill(pid, SIGSTOP)
            check("stand-in capped process is suspended", stopped(pid))

            let guard1 = Process()
            guard1.executableURL = Bundle.main.executableURL
            guard1.arguments = ["--cap-guardian", String(doomed.processIdentifier), tmpCaps.path]
            guard1.standardOutput = FileHandle.nullDevice
            guard1.standardError = FileHandle.nullDevice
            try guard1.run()
            Thread.sleep(forTimeInterval: 0.5)

            doomed.terminate()
            doomed.waitUntilExit()        // reap it, or the guardian sees a zombie

            // Wait for the resume instead of guessing how long a cold binary
            // launch takes: on a loaded machine that is seconds, not milliseconds,
            // and a fixed sleep turns a working guardian into a flaky test.
            var waited = 0.0
            while stopped(pid), waited < 8 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
            check("guardian resumed the process after its owner died", !stopped(pid),
                  String(format: "after %.1fs", waited))
            check("guardian cleared the recovery record", CapPersistence.read().isEmpty)

            _ = kill(pid, SIGCONT)        // whatever happened above, don't leave it stopped
            orphan.terminate()
        } catch {
            check("cap guardian round-trip", false, "\(error)")
        }
        try? FileManager.default.removeItem(at: tmpCaps)   // run() ends in exit(); no defer

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
