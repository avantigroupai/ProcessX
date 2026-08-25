import Darwin
import Foundation

/// A process's launch arguments, read once and remembered.
///
/// argv is fixed at exec, so a pid's answer never changes — which is what makes
/// caching safe and makes this cheap enough to ask from a view body. It is read
/// straight from the kernel (KERN_PROCARGS2), the same source `ps` uses; no
/// subprocess, no text parsing of someone else's output.
///
/// Only same-user processes answer. Anything else — another user's process, one
/// that exited between the sample and the question — comes back empty, and every
/// caller has to treat empty as "don't know" rather than "no".
enum ProcArgs {
    /// The start time travels with the arguments, because a pid on its own is
    /// not an identity: the kernel recycles pids, a browser churns renderers all
    /// day, and answering from the previous tenant's argv would label the wrong
    /// row — a tab renderer as an extension, or the reverse.
    private struct Entry { let startedAt: UInt64; let args: String }
    private static var cache: [pid_t: Entry] = [:]

    /// How many times the kernel was actually asked. The cache is only worth
    /// having if this stays flat across frames, so the self-test watches it.
    private(set) static var readCount = 0

    /// - Parameter startedAt: the sample's `startedAt`. A cached entry from a
    ///   different start time is a different process and is discarded. Pass 0
    ///   only when there is nothing to check against.
    static func string(for pid: pid_t, startedAt: UInt64 = 0) -> String {
        if let hit = cache[pid], hit.startedAt == startedAt { return hit.args }
        readCount += 1
        let entry = Entry(startedAt: startedAt, args: read(pid) ?? "")
        // A long-running monitor sees thousands of pids; the cache is a
        // convenience, not a ledger, so drop it wholesale rather than grow.
        if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }
        cache[pid] = entry
        return entry.args
    }

    /// True only when we actually read the arguments AND they contain `flag`.
    /// An unreadable process is never "true", so callers can't mistake silence
    /// for an answer.
    static func hasFlag(_ flag: String, pid: pid_t, startedAt: UInt64 = 0) -> Bool {
        let s = string(for: pid, startedAt: startedAt)
        return !s.isEmpty && s.contains(flag)
    }

    private static func read(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), exec path, padding NULs, then argc NUL-separated
        // arguments. We only ever match flags, so the separators become spaces
        // and the whole block is treated as one string.
        let body = buf[4..<min(size, buf.count)].map { $0 == 0 ? UInt8(ascii: " ") : $0 }
        return String(decoding: body, as: UTF8.self)
    }
}
