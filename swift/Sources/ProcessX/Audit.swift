import Darwin
import Foundation

/// Append-only log of every priority change, with the call site that caused it.
///
/// This exists because a batch of throttles once appeared that could not be
/// attributed after the fact. A tool that can reprioritise 90 of your processes
/// must be able to answer "what did this, and when" — the store alone only says
/// *that* it happened.
///
/// ~/Library/Logs/ProcessX/audit.log — rotated when it exceeds ~5 MB.
enum Audit {
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ProcessX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.log")
    }()

    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let queue = DispatchQueue(label: "processx.audit")

    static func log(_ message: String) {
        // Two frames up is the caller of ThrottleStore.add/remove — the actual
        // decision site (button handler, QuickFast, auto-tame tick).
        let caller = Thread.callStackSymbols.dropFirst(2).prefix(3)
            .map { symbol -> String in
                let parts = symbol.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count > 3 ? String(parts[3]) : symbol
            }
            .joined(separator: " <- ")

        let line = "\(fmt.string(from: Date())) pid=\(getpid()) \(message) via \(caller)\n"
        queue.async {
            rotateIfNeeded()
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Keep the log bounded: archive to audit.log.1 and start fresh.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxBytes else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("audit.log.1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    static var path: String { url.path }
}
