import Darwin
import Foundation

/// Append-only log of every priority change, with the call site that caused it.
///
/// This exists because a batch of throttles once appeared that could not be
/// attributed after the fact. A tool that can reprioritise 90 of your processes
/// must be able to answer "what did this, and when" — the store alone only says
/// *that* it happened.
///
/// ~/Library/Logs/ProcessX/audit.log
enum Audit {
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
                // "4  ProcessX  0x1004  ProcessX.Monitor.throttle(...) + 123" -> the symbol
                let parts = symbol.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count > 3 ? String(parts[3]) : symbol
            }
            .joined(separator: " <- ")

        let line = "\(fmt.string(from: Date())) pid=\(getpid()) \(message) via \(caller)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static var path: String { url.path }
}
