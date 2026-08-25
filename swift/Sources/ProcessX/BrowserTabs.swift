import AppKit
import Foundation

/// A real, named browser tab — obtained via Apple Events (AppleScript), the only
/// public way to see tab titles on macOS. A renderer PID can't be mapped to a
/// tab (the OS doesn't expose it), so we ask the browser itself.
struct BrowserTab: Identifiable, Sendable, Equatable {
    let windowIndex: Int          // 1-based, AppleScript window order
    let tabIndex: Int             // 1-based, within the window
    let active: Bool              // the window's frontmost tab
    let title: String
    let url: String
    var id: String { "\(windowIndex).\(tabIndex)" }

    /// Bare host for the dim secondary label ("github.com").
    var host: String {
        guard let h = URLComponents(string: url)?.host, !h.isEmpty else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// What to call the tab in one line. A page that hasn't set a title still
    /// has a host, and "github.com" beats "Untitled".
    var displayName: String {
        if !title.isEmpty { return title }
        return host.isEmpty ? "Untitled" : host
    }
}

enum BrowserEngine { case chromium, safari }

enum BrowserTabs {
    /// Browsers that speak Chrome's scripting dictionary (tabs/windows/URL/title).
    static let chromiumApps: Set<String> = [
        "Google Chrome", "Google Chrome Canary", "Google Chrome Dev", "Google Chrome Beta",
        "Brave Browser", "Brave Browser Beta", "Microsoft Edge", "Microsoft Edge Beta",
        "Vivaldi", "Opera", "Chromium",
    ]
    static let safariApps: Set<String> = ["Safari", "Safari Technology Preview"]

    static func engine(for appName: String) -> BrowserEngine? {
        if chromiumApps.contains(appName) { return .chromium }
        if safariApps.contains(appName) { return .safari }
        return nil
    }

    struct TabsError: Error, Sendable { let message: String }   // .message == "not-permitted" for TCC denial
    private static let notPermitted = "not-permitted"

    /// List the browser's open tabs. Never launches the browser — returns [] if it
    /// isn't running. Safe to call off the main thread.
    static func list(appName: String) -> Result<[BrowserTab], TabsError> {
        guard let engine = engine(for: appName) else { return .success([]) }
        let running = NSWorkspace.shared.runningApplications.contains { $0.localizedName == appName }
        guard running else { return .success([]) }
        let src = engine == .chromium ? chromiumListSource(appName) : safariListSource(appName)
        return run(src).map(parse)
    }

    /// Bring the browser forward with the given tab selected in its window.
    static func focus(appName: String, tab: BrowserTab) -> TabsError? {
        guard let engine = engine(for: appName) else { return TabsError(message: "unsupported browser") }
        let src = engine == .chromium
            ? chromiumFocusSource(appName, tab.windowIndex, tab.tabIndex)
            : safariFocusSource(appName, tab.windowIndex, tab.tabIndex)
        if case .failure(let e) = run(src) { return e }
        return nil
    }

    // MARK: - AppleScript execution

    private static func run(_ source: String) -> Result<String, TabsError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(TabsError(message: "could not compile script"))
        }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err = err {
            let n = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 = errAEEventNotPermitted (Automation permission denied/not yet granted).
            if n == -1743 { return .failure(TabsError(message: notPermitted)) }
            let m = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(n)"
            return .failure(TabsError(message: m))
        }
        return .success(out.stringValue ?? "")
    }

    // Fields per record: window \t tab \t active \t url \t title.
    // URL is placed before the title because a URL never contains a tab/newline,
    // whereas a title can — so we split the first four fields and keep the rest.
    private static func parse(_ s: String) -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5, let w = Int(f[0]), let t = Int(f[1]) else { continue }
            let url = f[3] == "missing value" ? "" : f[3]
            let title = f[4...].joined(separator: "\t")
            tabs.append(BrowserTab(windowIndex: w, tabIndex: t, active: f[2] == "true", title: title, url: url))
        }
        return tabs
    }

    // MARK: - script sources

    private static func chromiumListSource(_ app: String) -> String {
        """
        tell application "\(app)"
            set _out to {}
            set _w to 0
            repeat with win in windows
                set _w to _w + 1
                set _ai to 0
                try
                    set _ai to active tab index of win
                end try
                set _t to 0
                repeat with tb in tabs of win
                    set _t to _t + 1
                    set _u to (URL of tb as text)
                    set _ti to (title of tb as text)
                    set end of _out to (_w as text) & "\\t" & (_t as text) & "\\t" & ((_t is equal to _ai) as text) & "\\t" & _u & "\\t" & _ti
                end repeat
            end repeat
            set AppleScript's text item delimiters to (ASCII character 10)
            return (_out as text)
        end tell
        """
    }

    private static func chromiumFocusSource(_ app: String, _ w: Int, _ t: Int) -> String {
        """
        tell application "\(app)"
            set active tab index of window \(w) to \(t)
            set index of window \(w) to 1
            activate
        end tell
        """
    }

    private static func safariListSource(_ app: String) -> String {
        """
        tell application "\(app)"
            set _out to {}
            set _w to 0
            repeat with win in windows
                set _w to _w + 1
                set _cur to missing value
                try
                    set _cur to current tab of win
                end try
                set _t to 0
                try
                    repeat with tb in tabs of win
                        set _t to _t + 1
                        set _isact to false
                        try
                            set _isact to (tb is equal to _cur)
                        end try
                        set end of _out to (_w as text) & "\\t" & (_t as text) & "\\t" & (_isact as text) & "\\t" & (URL of tb as text) & "\\t" & (name of tb as text)
                    end repeat
                end try
            end repeat
            set AppleScript's text item delimiters to (ASCII character 10)
            return (_out as text)
        end tell
        """
    }

    private static func safariFocusSource(_ app: String, _ w: Int, _ t: Int) -> String {
        """
        tell application "\(app)"
            set current tab of window \(w) to tab \(t) of window \(w)
            set index of window \(w) to 1
            activate
        end tell
        """
    }
}
