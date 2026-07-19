import Foundation

/// Which processes may be touched, and which QuickFast/auto-tame should target.
/// This is the ported policy layer — the decisions, not the plumbing.
enum Policy {

    /// Never throttled, even on explicit request: slowing the window server or
    /// the login session is the opposite of what this tool is for.
    static let critical: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "ControlCenter", "NotificationCenter", "Spotlight",
        "coreaudiod", "bluetoothd", "tccd", "securityd", "opendirectoryd",
        "distnoted", "cfprefsd", "runningboardd", "watchdogd", "logd", "notifyd",
        "launchservicesd", "hidd", "powerd", "configd", "mDNSResponder", "syslogd",
        "UserEventAgent", "coreservicesd", "iconservicesd", "pboard", "fontd",
        "diskarbitrationd", "universalaccessd", "backboardd",
    ]

    /// Real-time audio/video — throttling these stutters a live call or playback.
    /// The name can appear as a bundle segment ("zoom.us.app/…/aomhost"), so it may
    /// be followed by ".app" as well as a slash, space, or end of string. Without
    /// the optional ".app" the encoder helpers *inside* these bundles slip through
    /// — which is exactly the bug the JS version shipped with.
    static let mediaSafe = regex(
        #"(^|/)(Music|Spotify|VLC|Podcasts|zoom\.us|FaceTime|Microsoft Teams|Webex|OBS|QuickTime Player|Photo Booth)(\.app)?(/|$| )"#)

    /// Background agents QuickFast targets by name regardless of exact CPU.
    static let quickFastNames = [regex(#"claude"#), regex(#"cowork"#), regex(#"anthropic"#)]

    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Warp", "Alacritty",
                                         "kitty", "WezTerm", "wezterm-gui", "Ghostty", "Hyper", "Tabby"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "dash",
                                      "login", "tmux", "screen", "script", "nohup", "env", "caffeinate", "sudo"]
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3",
                                            "python2", "ruby", "perl", "java", "osascript"]

    private static func regex(_ p: String) -> NSRegularExpression {
        // Patterns are compile-time literals; a throw here is a programmer error.
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Why this process may not be touched, or nil if it may.
    /// `manual` = the user clicked it directly, which relaxes the media guard
    /// (QuickFast and auto-tame must never surprise-throttle a call; an explicit
    /// click is not a surprise).
    static func ineligibleReason(_ p: ProcSample, manual: Bool, myUID: uid_t, selfPID: pid_t) -> String? {
        if p.pid == selfPID || p.pid == 0 { return "is ProcessX itself" }
        if p.uid != myUID { return "owned by another user (needs admin)" }
        if critical.contains(p.name) { return "protected system process" }
        if !manual && matches(mediaSafe, p.path) { return "media/call app (skipped automatically)" }
        return nil
    }
}
