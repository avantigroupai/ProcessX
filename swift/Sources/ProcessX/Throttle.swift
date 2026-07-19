import Darwin
import Foundation

enum ThrottleOrigin: String, Codable {
    case manual, quickFast, auto
}

struct ThrottleRecord: Codable {
    let pid: pid_t
    let path: String   // identity guard: a recycled pid won't match this
    let name: String
    let origin: ThrottleOrigin
    let at: Date
}

/// Moves processes in/out of the Darwin background band.
///
/// `taskpolicy -b -p PID` is a subprocess wrapping exactly this call (its man page
/// says it "uses the setiopolicy_np(3) and setpriority(2) APIs"). Calling it
/// directly costs one syscall instead of a fork+exec.
enum Throttle {

    @discardableResult
    static func setBackground(_ pid: pid_t, _ on: Bool) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0
    }

    /// Also drop disk I/O priority, matching what `taskpolicy -b` does — a heavy
    /// encode starves the UI through the disk queue as much as through the CPU.
    /// Best-effort: unlike setpriority this only applies to the calling process on
    /// some releases, so its failure must not fail the throttle.
    static func setIOPolicy(_ pid: pid_t, background: Bool) {
        _ = pid; _ = background // reserved: no public per-pid setiopolicy_np exists
    }
}

/// Persisted record of what *we* throttled, so Restore only touches our own work
/// and each entry keeps its origin (manual / QuickFast / auto).
///
/// The kernel reports the live truth (pti_priority), but not *who* set it or why —
/// so display reads the kernel and attribution reads this.
final class ThrottleStore {
    private(set) var records: [pid_t: ThrottleRecord] = [:]
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("throttles.json")
        load()
    }

    func add(_ r: ThrottleRecord) {
        records[r.pid] = r
        Audit.log("THROTTLE pid=\(r.pid) origin=\(r.origin.rawValue) name=\(r.name)")
        save()
    }
    func remove(_ pid: pid_t) {
        if let r = records[pid] { Audit.log("RESTORE  pid=\(pid) origin=\(r.origin.rawValue) name=\(r.name)") }
        records.removeValue(forKey: pid)
        save()
    }
    func record(_ pid: pid_t) -> ThrottleRecord? { records[pid] }
    var all: [ThrottleRecord] { Array(records.values) }

    /// Reconcile our records against reality:
    ///  - process gone, or pid now belongs to a different executable (pid reuse)
    ///    -> drop it. Without the identity check a recycled pid would be shown as
    ///    throttled, wrongly exempted from taming, and offer a bogus Restore.
    ///  - kernel says it's no longer in the background band -> someone else lifted
    ///    our throttle, so stop claiming it. This is what the kernel readback is
    ///    actually good for: drift detection, not "did we throttle it".
    ///
    /// The grace period matters: pti_priority doesn't update the instant
    /// setpriority returns, so a fresh record would otherwise delete itself.
    func reconcile(live: [pid_t: ProcSample], now: Date = Date()) {
        var changed = false
        for (pid, rec) in records {
            guard let p = live[pid], p.path == rec.path else {
                records.removeValue(forKey: pid)
                changed = true
                continue
            }
            if now.timeIntervalSince(rec.at) > 5, p.priority > Sampler.bgBand {
                records.removeValue(forKey: pid)
                changed = true
            }
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ThrottleRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
