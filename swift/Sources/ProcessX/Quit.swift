import AppKit
import Darwin
import Foundation

/// Ending a process, as opposed to slowing one down.
///
/// Every other action in ProcessX is reversible — a throttle is lifted by
/// Restore, a cap by Uncap. This one is not, and the two rungs it offers differ
/// in exactly that respect:
///
///  - **Quit** *asks*. For something macOS knows as an application that is the
///    same request the Dock's Quit sends, so the app runs its own shutdown: a
///    "Save changes?" sheet appears, and the app decides when to go — including
///    deciding not to. For everything else it is SIGTERM, which a well-behaved
///    daemon or CLI treats the same way.
///  - **Force quit** does not ask. SIGKILL cannot be caught, blocked or ignored:
///    unsaved work is gone, temporary files are left behind, and helper processes
///    are orphaned rather than shut down. It always works, which is the only
///    thing it has going for it.
///
/// A quit request is not a quit, which is why `hasExited` exists: the UI checks
/// back a few seconds later rather than claiming an outcome it never observed.
enum Quit {

    enum Mode: String {
        case ask, force
        var verb: String { self == .ask ? "Quit" : "Force Quit" }
    }

    /// Ask one process to end. Returns nil on success, or why it couldn't be sent.
    ///
    /// `path` is the identity guard, the same one caps use: pids are recycled, and
    /// a sample is up to two seconds old. Killing the wrong process because the
    /// number was reused is a far worse failure here than it is for a throttle —
    /// there is no Restore afterwards — so the executable path is re-read
    /// immediately before signalling and must still match.
    @discardableResult
    static func send(pid: pid_t, path: String, mode: Mode) -> String? {
        guard pid > 0, pid != getpid() else { return "that's ProcessX itself" }
        guard let live = executablePath(of: pid) else { return "it has already exited" }
        guard live == path else { return "it exited; that process id now belongs to something else" }

        // A suspended process never runs, so it can neither see a SIGTERM nor
        // answer a quit request — asking a capped app to quit would look like the
        // button did nothing. SIGKILL needs no such courtesy (the kernel reaps a
        // stopped process just as happily), so only the polite path resumes first.
        if mode == .ask { _ = kill(pid, SIGCONT) }

        // The application-level path, when there is one: this is what makes Quit
        // different from SIGTERM. A Cocoa app has no SIGTERM handler — the default
        // disposition just ends it, unsaved work and all — so sending a signal
        // here would make "Quit" a second Force Quit wearing a friendlier label.
        if let app = NSRunningApplication(processIdentifier: pid) {
            if mode == .ask ? app.terminate() : app.forceTerminate() {
                Audit.log("QUIT     pid=\(pid) mode=\(mode.rawValue) via=app name=\((path as NSString).lastPathComponent)")
                return nil
            }
            // Refused (a helper with no event loop to ask, mostly). Fall through:
            // a signal still reaches it.
        }

        if kill(pid, mode == .ask ? SIGTERM : SIGKILL) == 0 {
            Audit.log("QUIT     pid=\(pid) mode=\(mode.rawValue) via=signal name=\((path as NSString).lastPathComponent)")
            return nil
        }
        switch errno {
        case ESRCH: return "it has already exited"
        case EPERM: return "the system refused (not yours to end)"
        default: return "the kernel refused it (errno \(errno))"
        }
    }

    /// Whether the pid is gone — or has become a different program, which for
    /// every purpose here is the same thing.
    static func hasExited(pid: pid_t, path: String) -> Bool {
        executablePath(of: pid).map { $0 != path } ?? true
    }
}
