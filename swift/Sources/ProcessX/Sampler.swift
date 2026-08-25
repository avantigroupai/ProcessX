import Darwin
import Foundation

struct ProcSample {
    var pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    var name: String      // short name (pbi_comm, or the path's last component)
    var path: String      // full executable path when readable
    var rss: UInt64
    var priority: Int32   // pti_priority — kernel truth: <= bgBand means throttled
    var cpuPct: Double    // % of ONE core over the last interval
    /// SIGSTOPped right now — by us (a cap's stopped phase) or by anything else.
    /// Read before capping: a process someone else suspended must not be adopted,
    /// because releasing the cap would resume something we never stopped.
    var isStopped: Bool = false
    /// pbi_start_tvsec. A pid alone is not an identity — the kernel recycles
    /// them, and a browser that churns renderers all day will reuse one. pid +
    /// start time is the pair that actually names a process.
    var startedAt: UInt64 = 0
    var groupKey: String = ""
}

/// Reads the process table via libproc. No subprocesses, no text parsing.
final class Sampler {
    /// A task in the Darwin background band reports pti_priority 4; a normal
    /// foreground task reports ~26–31. Measured directly against taskpolicy -b/-B.
    static let bgBand: Int32 = 4

    /// SSTOP from <sys/proc.h> — the macro doesn't import into Swift.
    static let stoppedStatus: UInt32 = 4

    /// pti_total_user/pti_total_system are in **mach absolute time units, not
    /// nanoseconds**. On Apple Silicon the timebase is 125/3 (24 MHz), so treating
    /// ticks as ns under-reports CPU by ~41x — enough that auto-tame would never
    /// fire. On Intel numer == denom == 1, which is exactly why this bug hides
    /// there and must be converted explicitly rather than assumed.
    static let ticksToNanos: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    private var prevCPUTime: [pid_t: UInt64] = [:]
    private var prevStamp: CFAbsoluteTime = 0

    /// One scratch buffer for every `proc_pidpath` call, reused across the whole
    /// walk. Allocating a fresh 4 KB `[CChar]` per process — a thousand of them
    /// per tick — cost more than the syscall it was passed to: measured 4.2 ms
    /// per tick allocating, 1.7 ms reusing.
    private var pathBuf = [CChar](repeating: 0, count: pathMax)

    /// Sample every process. CPU% is a true interval measurement: the delta of
    /// (user+system) task time over elapsed wall time. `ps` reports a decaying
    /// average instead, which lags real load — this doesn't.
    func sample() -> [ProcSample] {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = prevStamp == 0 ? 0 : now - prevStamp

        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        // Ask for headroom: processes can spawn between the sizing call and the read.
        let capacity = Int(count) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let n = Int(count) / MemoryLayout<pid_t>.size

        var out: [ProcSample] = []
        out.reserveCapacity(n)
        var nextCPUTime: [pid_t: UInt64] = [:]
        nextCPUTime.reserveCapacity(n)

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var info = proc_taskallinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info,
                                 Int32(MemoryLayout<proc_taskallinfo>.size))
            // A process that exited between listing and reading just vanishes.
            guard sz == Int32(MemoryLayout<proc_taskallinfo>.size) else { continue }

            let cpuTime = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            nextCPUTime[pid] = cpuTime

            var pct = 0.0
            if elapsed > 0, let prev = prevCPUTime[pid], cpuTime >= prev {
                // One core fully busy = 1e9 ns of task time per second of wall clock.
                let ns = Double(cpuTime - prev) * Self.ticksToNanos
                pct = ns / 1_000_000_000.0 / elapsed * 100.0
            }

            let comm = withUnsafeBytes(of: info.pbsd.pbi_comm) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let path = path(of: pid)

            out.append(ProcSample(
                pid: pid,
                ppid: pid_t(info.pbsd.pbi_ppid),
                uid: info.pbsd.pbi_uid,
                // pbi_comm truncates at 16 chars; the path's last component is the
                // real name when we can read it.
                name: path.isEmpty ? comm : (path as NSString).lastPathComponent,
                path: path.isEmpty ? comm : path,
                rss: info.ptinfo.pti_resident_size,
                priority: info.ptinfo.pti_priority,
                cpuPct: pct,
                isStopped: info.pbsd.pbi_status == Self.stoppedStatus,
                startedAt: UInt64(info.pbsd.pbi_start_tvsec)
            ))
        }

        prevCPUTime = nextCPUTime
        prevStamp = now
        return out
    }

    /// First sample has no baseline, so every cpuPct is 0 and means nothing.
    var hasBaseline: Bool { prevStamp != 0 }

    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) — the macro doesn't import into Swift.
    private static let pathMax = 4 * 1024

    private func path(of pid: pid_t) -> String {
        // Fails for processes we can't inspect (other users, some system procs).
        // On failure the buffer keeps the previous pid's bytes, so a short-circuit
        // here is load-bearing: reading it anyway would attribute one process's
        // executable to another.
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return "" }
        return String(cString: pathBuf)
    }
}
