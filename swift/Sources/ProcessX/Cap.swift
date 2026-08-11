import Darwin
import Foundation

// MARK: - records

/// One process under a cap. The path is the identity guard: a recycled pid must
/// never be resumed — or worse, suspended — on the strength of the number alone.
struct CapTarget: Codable, Equatable {
    let pid: pid_t
    let path: String
}

/// A cap applies to a whole `ProcGroup`, not a pid: an app is its helpers, and
/// suspending Chrome's browser process while its 90 renderers run flat out would
/// hold nothing under anything.
struct CapRecord: Codable, Equatable, Identifiable {
    let key: String            // ProcGroup.key
    let name: String
    var percent: Double        // % of ONE core — the same unit as the CPU column
    var targets: [CapTarget]
    var at: Date
    /// Last measured CPU for the whole capped set, so the UI can show whether the
    /// cap is actually holding.
    var achieved: Double = 0
    var id: String { key }
}

/// The on-disk list of what is currently suspended-and-resumed by us.
///
/// This file is not a convenience: it is the recovery record. It is written
/// *before* the first SIGSTOP so that a crash one instruction later still leaves
/// something that says which processes need a SIGCONT.
enum CapPersistence {
    /// Redirectable so `--selftest` can exercise the real recovery path against a
    /// throwaway file instead of clobbering the record of a running instance.
    nonisolated(unsafe) static var url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("caps.json")
    }()

    static func write(_ records: [CapRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> [CapRecord] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([CapRecord].self, from: data) else { return [] }
        return list
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// `proc_pidpath` for one pid — the identity check, available outside Sampler.
func executablePath(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * 1024)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

// MARK: - emergency resume

/// The last line of defence, and the reason a cap is safe to ship.
///
/// A process we SIGSTOP stays stopped forever if we die before the matching
/// SIGCONT. Signal handlers can't allocate, take locks, or call Swift runtime
/// entry points — so the pid list lives in a fixed C buffer that the handler only
/// reads, and the handler only calls `kill(2)`, which is async-signal-safe.
///
/// This covers crashes we can catch (SIGSEGV, SIGABRT, …). SIGKILL and a kernel
/// panic can't be caught by anyone; `CapGuardian` covers those.
enum CapEmergency {
    private static let capacity = 1024
    private nonisolated(unsafe) static let buffer =
        UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
    /// Written only by the cap queue, read by signal handlers. `sig_atomic_t` is
    /// exactly the type the C standard promises is safe to touch from a handler.
    private nonisolated(unsafe) static var liveCount: sig_atomic_t = 0

    /// Publish the current set of suspendable pids. Called on every cap change.
    static func set(_ pids: [pid_t]) {
        let n = min(pids.count, capacity)
        for i in 0..<n { buffer[i] = pids[i] }
        liveCount = sig_atomic_t(n)
    }

    /// Async-signal-safe: reads a plain buffer and calls kill(2). Nothing else.
    static func resumeAll() {
        let n = Int(liveCount)
        for i in 0..<n { _ = kill(buffer[i], SIGCONT) }
    }

    /// Catch every fatal signal we're allowed to catch, resume, then die the way
    /// we were going to anyway (re-raise with the default handler so a crash is
    /// still a crash and still writes a report).
    static func install() {
        let fatal: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT,
                              SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS]
        for sig in fatal {
            signal(sig) { s in
                CapEmergency.resumeAll()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        atexit { CapEmergency.resumeAll() }
    }
}

// MARK: - guardian

/// `ProcessX --cap-guardian <parent-pid> <caps.json>` — a second copy of this
/// binary that does nothing but outlive a SIGKILL.
///
/// It waits for the parent to disappear, then SIGCONTs everything the parent had
/// suspended. Without it, `kill -9 ProcessX` at the wrong millisecond leaves a
/// capped app frozen with no way back except a reboot or a manual `kill -CONT`.
enum CapGuardian {
    static func run(parent: pid_t, listPath: String) -> Never {
        // The path is passed explicitly rather than recomputed: the parent owns
        // which file is authoritative, and a guardian reading a different one
        // resumes nothing.
        CapPersistence.url = URL(fileURLWithPath: listPath)

        // Leave the parent's process group and session, or a group-wide kill
        // (Ctrl-C in a terminal, a crash reaper) takes the guardian down with the
        // very process it exists to survive.
        _ = setsid()

        let kq = kqueue()
        if kq >= 0 {
            var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC),
                            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
            // Registration fails with ESRCH if the parent is already gone — which
            // is not an error here, it's the signal to act now.
            if kevent(kq, &ev, 1, nil, 0, nil) == 0 {
                var out = kevent()
                _ = kevent(kq, nil, 0, &out, 1, nil)   // blocks until the parent exits
            }
        }
        // Belt and braces: confirm by polling, which is also the fallback path if
        // kqueue was unavailable.
        while kill(parent, 0) == 0 { usleep(500_000) }

        var resumed = 0
        for record in CapPersistence.read() {
            for t in record.targets {
                // Identity guard: never signal a pid that now belongs to someone else.
                guard executablePath(of: t.pid) == t.path else { continue }
                if kill(t.pid, SIGCONT) == 0 { resumed += 1 }
            }
        }
        CapPersistence.clear()
        FileHandle.standardError.write(Data("ProcessX cap guardian: resumed \(resumed) process(es)\n".utf8))
        exit(0)
    }
}

// MARK: - the capper

private final class LiveCap {
    let key: String
    let name: String
    var percent: Double
    var targets: [CapTarget]
    /// Share of each period the group is allowed to run. Starts at 1 so an app
    /// that was never going to hit its cap is never stopped for it.
    var runFraction: Double = 1
    var running = true
    var lastTicks: UInt64 = 0
    var lastStamp: CFAbsoluteTime = 0
    var achieved: Double = 0
    let at: Date
    /// Bumped to invalidate scheduled continuations when a cap is replaced.
    var gen: Int

    init(key: String, name: String, percent: Double, targets: [CapTarget], gen: Int, at: Date = Date()) {
        self.key = key; self.name = name; self.percent = percent
        self.targets = targets; self.gen = gen; self.at = at
    }

    var record: CapRecord {
        CapRecord(key: key, name: name, percent: percent, targets: targets, at: at, achieved: achieved)
    }
}

/// Holds a group of processes under a CPU percentage by duty-cycling
/// SIGSTOP/SIGCONT — the only mechanism macOS offers for a hard cap.
///
/// There is no per-process CPU quota to ask for: `RLIMIT_CPU_USAGE_MONITOR` only
/// *notices* a breach (it notifies or raises EXC_RESOURCE), it can't hold a
/// process under a number. So the cap is closed-loop instead: run the group for
/// part of each period, measure what it actually got, and adjust.
///
/// Every mutation runs on `queue`; nothing here touches the main thread.
final class Capper: @unchecked Sendable {
    /// 200 ms is the compromise: short enough that a capped UI still repaints
    /// several times a second, long enough that two signals per period is noise.
    private static let periodMs = 200
    /// Never freeze completely. A group always gets a sliver of every period, so a
    /// capped app can still process a quit request and can still be measured.
    /// The floor is also the limit of the feature: a cap can't hold a process
    /// below ~2 % of what it would use unconstrained.
    private static let minRunMs = 4
    private static var minFraction: Double { Double(minRunMs) / Double(periodMs) }
    /// How much of the way to the newly-computed ideal we move each period.
    /// Below ~1 the loop damps overshoot on bursty processes.
    private static let gain = 0.6

    private let queue = DispatchQueue(label: "processx.cap", qos: .userInitiated)
    private var caps: [String: LiveCap] = [:]      // queue-confined
    private var generation = 0
    private var guardian: Process?

    // MARK: reads

    func snapshot() -> [CapRecord] {
        queue.sync { caps.values.map(\.record).sorted { $0.at > $1.at } }
    }

    // MARK: writes

    /// Create or re-target a cap. `targets` must already have passed the policy gate.
    func set(key: String, name: String, percent: Double, targets: [CapTarget]) {
        queue.async {
            if let existing = self.caps[key] {
                self.retarget(existing, to: targets)
                existing.percent = percent
                self.persist()
                Audit.log("CAP      key=\(key) name=\(name) pct=\(Int(percent)) (updated)")
                return
            }
            self.generation += 1
            let c = LiveCap(key: key, name: name, percent: percent, targets: targets, gen: self.generation)
            self.caps[key] = c
            // Order is load-bearing: the recovery record and the guardian must both
            // exist before any process is suspended, not after.
            self.persist()
            self.ensureGuardian()
            Audit.log("CAP      key=\(key) name=\(name) pct=\(Int(percent)) pids=\(targets.count)")
            self.step(key: key, gen: c.gen)
        }
    }

    func clear(_ key: String) {
        queue.async { self.clearLocked(key) }
    }

    func clearAll() {
        // Array(): clearLocked removes from `caps`, and iterating a dictionary's
        // own key view while mutating it is undefined behaviour.
        queue.async { for key in Array(self.caps.keys) { self.clearLocked(key) } }
    }

    /// Blocking variant for app termination, where an async hop would lose the race
    /// with `exit()`.
    func clearAllSync() {
        queue.sync { for key in Array(self.caps.keys) { self.clearLocked(key) } }
    }

    /// Refresh each cap's pid set from a fresh sample: helpers come and go, and a
    /// cap that only knows the pids it was created with slowly stops capping.
    /// A key missing from `fresh` means the group is gone, so the cap goes with it.
    /// The caller resolves group → pids on the main actor and hands over a plain
    /// value; the cap queue never reaches back into the model.
    func refresh(_ fresh: [String: [CapTarget]]) {
        queue.async {
            var changed = false
            for key in Array(self.caps.keys) {           // clearLocked mutates `caps`
                guard let c = self.caps[key] else { continue }
                guard let list = fresh[key], !list.isEmpty else {
                    self.clearLocked(key)                // persists on its own
                    continue
                }
                if list != c.targets {
                    self.retarget(c, to: list)
                    changed = true
                }
            }
            // Only touch the disk when the pid set actually moved — this runs every
            // two seconds for as long as a cap is held.
            if changed { self.persist() }
        }
    }

    // MARK: - internals (all queue-confined)

    private func clearLocked(_ key: String) {
        guard let c = caps.removeValue(forKey: key) else { return }
        c.gen = -1                                   // strands any pending continuation
        // Unconditional, not `if !c.running`: a SIGCONT to a running process is a
        // no-op, whereas a missed one is a frozen app.
        for t in c.targets { _ = kill(t.pid, SIGCONT) }
        persist()
        if caps.isEmpty { stopGuardian() }
        Audit.log("UNCAP    key=\(c.key) name=\(c.name)")
    }

    /// Swap a cap's pid set, resuming anything being dropped — a target removed
    /// during the stopped phase would otherwise never be resumed by anyone.
    private func retarget(_ c: LiveCap, to fresh: [CapTarget]) {
        let keep = Set(fresh.map(\.pid))
        for t in c.targets where !keep.contains(t.pid) { _ = kill(t.pid, SIGCONT) }
        // A new helper joining mid-period simply runs until the next stop edge.
        if !c.running { for t in fresh where !c.targets.contains(t) { _ = kill(t.pid, SIGSTOP) } }
        c.targets = fresh
    }

    private func persist() {
        let records = caps.values.map(\.record)
        CapPersistence.write(records)
        CapEmergency.set(records.flatMap { $0.targets.map(\.pid) })
    }

    private func suspend(_ c: LiveCap) {
        guard c.running else { return }
        for t in c.targets { _ = kill(t.pid, SIGSTOP) }
        c.running = false
    }

    private func resume(_ c: LiveCap) {
        guard !c.running else { return }
        for t in c.targets { _ = kill(t.pid, SIGCONT) }
        c.running = true
    }

    /// One period: prune, measure, correct, then run-then-stop on a timer.
    private func step(key: String, gen: Int) {
        guard let c = caps[key], c.gen == gen else { return }

        c.targets.removeAll { t in
            if kill(t.pid, 0) == 0 { return false }
            return errno == ESRCH                     // gone, not merely unsignalable
        }
        guard !c.targets.isEmpty else {
            caps.removeValue(forKey: key)
            persist()
            if caps.isEmpty { stopGuardian() }
            Audit.log("UNCAP    key=\(key) name=\(c.name) (all processes exited)")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let ticks = c.targets.reduce(UInt64(0)) { $0 &+ (Self.cpuTicks($1.pid) ?? 0) }
        // A drop means the target set changed under us; skip one correction rather
        // than feed the controller a negative delta.
        if c.lastStamp > 0, ticks >= c.lastTicks {
            let elapsed = now - c.lastStamp
            if elapsed > 0 {
                let ns = Double(ticks - c.lastTicks) * Sampler.ticksToNanos
                c.achieved = ns / 1_000_000_000 / elapsed * 100
                // CPU is very nearly linear in run time, so the ideal fraction is
                // just the current one scaled by how far off we are. An idle group
                // (achieved ≈ 0) is pushed back to full speed: a cap is a ceiling,
                // never a floor.
                let target = max(c.percent, 0.5)
                let ideal = c.achieved < 0.05 ? 1.0 : min(1.0, c.runFraction * target / c.achieved)
                c.runFraction = min(1, max(Self.minFraction, c.runFraction + Self.gain * (ideal - c.runFraction)))
            }
        }
        c.lastTicks = ticks
        c.lastStamp = now

        let runMs = min(Self.periodMs,
                        max(Self.minRunMs, Int((c.runFraction * Double(Self.periodMs)).rounded())))
        resume(c)

        guard runMs < Self.periodMs else {
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.periodMs)) { [weak self] in
                self?.step(key: key, gen: gen)
            }
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(runMs)) { [weak self] in
            guard let self, let c = self.caps[key], c.gen == gen else { return }
            self.suspend(c)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(Self.periodMs - runMs)) { [weak self] in
                self?.step(key: key, gen: gen)
            }
        }
    }

    private static func cpuTicks(_ pid: pid_t) -> UInt64? {
        var t = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
        guard n == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return t.pti_total_user &+ t.pti_total_system
    }

    // MARK: guardian lifecycle

    private func ensureGuardian() {
        if let g = guardian, g.isRunning { return }
        guard let exe = Bundle.main.executableURL ?? executablePath(of: getpid()).map(URL.init(fileURLWithPath:))
        else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--cap-guardian", String(getpid()), CapPersistence.url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            guardian = p
            Audit.log("CAPGUARD started pid=\(p.processIdentifier)")
        } catch {
            // Not fatal — CapEmergency still covers every catchable death — but the
            // SIGKILL hole is open, so it belongs in the log.
            Audit.log("CAPGUARD failed to start: \(error)")
        }
    }

    private func stopGuardian() {
        guard let g = guardian else { return }
        guardian = nil
        if g.isRunning { g.terminate() }
        Audit.log("CAPGUARD stopped")
    }

    // MARK: startup recovery

    /// Called once at launch: if a previous run died holding processes suspended
    /// (and the guardian died with it), let them go. Caps are deliberately *not*
    /// re-established — inheriting an invisible suspension across a crash is how
    /// you get an app that mysteriously stutters.
    static func releaseOrphans() {
        let stale = CapPersistence.read()
        guard !stale.isEmpty else { return }
        var resumed = 0
        for record in stale {
            for t in record.targets where executablePath(of: t.pid) == t.path {
                if kill(t.pid, SIGCONT) == 0 { resumed += 1 }
            }
        }
        CapPersistence.clear()
        Audit.log("CAPRESUME startup released \(resumed) process(es) left by a previous run")
    }
}
