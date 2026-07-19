import Foundation

/// Plain-language "what is this?" for a process or app group. macOS ships
/// hundreds of opaquely-named daemons; this turns the common ones into a one-line
/// explanation, and falls back to a sensible category for the rest. Anything the
/// catalog doesn't know still gets a web-lookup button in the UI.
struct ProcInfo {
    var title: String
    var category: String
    var detail: String
    var path: String
}

enum ProcessCatalog {
    /// Exact process/app names → what they do.
    private static let known: [String: String] = [
        // Core system
        "launchd": "The system's first process — starts and supervises every other process and service.",
        "kernel_task": "The macOS kernel itself. High CPU here is often the system cooling the Mac by holding back other work.",
        "WindowServer": "Draws everything you see — the macOS display server that composites all windows.",
        "loginwindow": "Manages your login session and the login screen.",
        "SystemUIServer": "Runs the right side of the menu bar (status items, clock, battery).",
        "ControlCenter": "The menu-bar Control Center and its modules (Wi-Fi, Bluetooth, Sound…).",
        "NotificationCenter": "Notification Center and banners.",
        "Dock": "The Dock, Mission Control, and Spaces.",
        "Finder": "The Finder — desktop, file windows, and the Trash.",
        "WindowManager": "Stage Manager and window tiling.",
        "runningboardd": "Manages the lifecycle and resource limits of apps and processes.",
        "powerd": "Power management — sleep, wake, and battery.",
        "backboardd": "Low-level event and display plumbing.",
        "hidd": "Handles input from the keyboard, trackpad, and mouse.",

        // Spotlight / search / on-device intelligence
        "mds": "Spotlight — the metadata server that runs search indexing.",
        "mds_stores": "Spotlight index storage and maintenance.",
        "mdworker": "A Spotlight worker indexing a file's contents right now.",
        "mdworker_shared": "A shared Spotlight indexing worker.",
        "mdbulkimport": "Spotlight bulk-importing metadata.",
        "corespotlightd": "Spotlight index for app content (Mail, Messages, etc.).",
        "spotlightknowledged": "On-device Spotlight knowledge and suggestions.",
        "suggestd": "Learns on-device to power Siri Suggestions and smart results.",
        "parsecd": "Backs Spotlight's Siri Suggestions and web results.",
        "knowledgeconstructiond": "Builds the on-device knowledge graph for Siri/Spotlight.",
        "duetexpertd": "Predicts your habits for Siri Suggestions, Handoff, and battery life.",
        "duetknowledged": "Stores the on-device usage model behind Siri Suggestions.",
        "proactived": "Proactive suggestions (Siri, Spotlight, Maps).",

        // iCloud / networking / sync
        "cloudd": "iCloud — syncs your data with Apple's servers.",
        "bird": "iCloud Drive — syncs documents and app data.",
        "nsurlsessiond": "Background downloads and uploads (iCloud, App Store, Photos…).",
        "apsd": "Apple Push Notification service — delivers push notifications.",
        "identityservicesd": "iMessage/FaceTime identity and Continuity handoff.",
        "rapportd": "Continuity — Handoff, Universal Clipboard, Sidecar, phone calls.",
        "sharingd": "AirDrop, Handoff, Instant Hotspot, and Continuity.",
        "coreduetd": "Coordinates Handoff and Continuity across your devices.",
        "symptomsd": "Watches network quality to pick the best connection.",
        "mDNSResponder": "Bonjour — discovers printers, AirPlay, and local network services.",
        "networkserviceproxy": "Private Relay / network service proxying.",
        "trustd": "Verifies certificates for secure (TLS) connections.",
        "locationd": "Location Services.",

        // Security / accounts
        "tccd": "Privacy gatekeeper — the permission prompts for camera, mic, files, etc.",
        "syspolicyd": "Gatekeeper — checks that apps are signed and allowed to run.",
        "amfid": "Verifies app code signatures before they run.",
        "securityd": "The Keychain and cryptographic services.",
        "opendirectoryd": "User accounts and directory services.",
        "akd": "AuthKit — signs you in to your Apple ID.",
        "secinitd": "Sets up each app's security sandbox as it launches.",

        // Prefs / notifications plumbing
        "cfprefsd": "Reads and writes app preferences (.plist files).",
        "distnoted": "Delivers notifications between processes.",
        "notifyd": "Low-level notification broker.",
        "UserEventAgent": "Runs small background agents that react to system events.",
        "diskarbitrationd": "Handles mounting and ejecting disks.",
        "fseventsd": "Watches the file system for changes (used by Time Machine, Spotlight).",

        // Media / photos
        "coreaudiod": "Core Audio — all sound on the Mac flows through it.",
        "bluetoothd": "The Bluetooth stack.",
        "photolibraryd": "Manages your Photos library.",
        "photoanalysisd": "Photos analyses faces, scenes, and memories when idle.",
        "mediaanalysisd": "Analyses media for Visual Look Up and Memories.",
        "avconferenced": "FaceTime audio/video.",
        "callservicesd": "Phone/FaceTime calls via Continuity.",

        // Updates / store
        "softwareupdated": "Checks for and downloads macOS updates.",
        "appstoreagent": "The App Store's background agent.",
        "commerce": "App Store purchases and receipts.",
        "installd": "Installs and updates apps.",
        "mobileassetd": "Downloads on-demand system assets (voices, fonts, dictionaries).",

        // Backup / storage
        "backupd": "Time Machine backups.",
        "revisiond": "Document version history (Versions).",
        "deleted": "Reclaims disk space by purging purgeable files.",

        // Virtualisation
        "com.apple.Virtualization.VirtualMachine": "A virtual machine running under Apple's Virtualization framework (Docker, a Linux VM, etc.).",

        // Anthropic
        "Claude": "Anthropic's Claude — the AI assistant (Desktop app or Claude Code).",
        "claude": "Claude Code — Anthropic's terminal coding agent.",
        "cowork": "An Anthropic Cowork session.",

        // Common apps (browsers especially, since their helpers look cryptic)
        "Google Chrome": "Google's web browser. Expand the row to see and jump to its tabs.",
        "Safari": "Apple's web browser. Expand the row to see and jump to its tabs.",
        "Brave Browser": "A Chromium web browser. Expand to see and jump to its tabs.",
        "Microsoft Edge": "Microsoft's Chromium web browser. Expand to see its tabs.",
        "Firefox": "Mozilla's web browser.",
        "Arc": "A Chromium web browser.",
        "Activity Monitor": "Apple's built-in process and resource monitor.",
        "Terminal": "Apple's terminal — hosts command-line sessions.",
        "iTerm2": "A terminal emulator — hosts command-line sessions.",
        "Slack": "Slack — team chat.",
        "Telegram": "Telegram — messaging.",
        "Spotify": "Spotify — music streaming.",
        "Music": "Apple Music.",
        "zoom.us": "Zoom — video calls.",
        "Code": "Visual Studio Code — a code editor.",
        "Cursor": "Cursor — an AI code editor.",

        // Interpreters / dev tools (shown as their own rows when running scripts)
        "node": "A Node.js program (a JavaScript/TypeScript app or tool).",
        "python": "A Python program.",
        "python3": "A Python program.",
        "ruby": "A Ruby program.",
        "java": "A Java program.",
        "go": "A Go program.",
        "rustc": "The Rust compiler.",
        "cargo": "The Rust build tool.",
        "ffmpeg": "Audio/video encoding or conversion — often very CPU-heavy.",
        "ollama": "Ollama — runs local AI models.",
        "docker": "The Docker CLI/daemon — container management.",
    ]

    /// Prefix/substring rules applied when there's no exact match.
    private static let rules: [(String, String)] = [
        ("Google Chrome Helper (Renderer)", "A Chrome tab or page — its own sandboxed process (expand the row to see and jump to the actual tab)."),
        ("Google Chrome Helper (GPU)", "Chrome's GPU process — draws pages and video."),
        ("Google Chrome Helper (Plugin)", "A Chrome plugin/utility process."),
        ("Google Chrome Helper", "A Chrome helper process."),
        ("com.apple.WebKit.WebContent", "A Safari/WebKit tab or web page process."),
        ("com.apple.WebKit.GPU", "WebKit's GPU process — draws web pages."),
        ("com.apple.WebKit.Networking", "WebKit's networking process."),
        ("Brave Browser Helper", "A Brave tab or helper process."),
        ("Microsoft Edge Helper", "An Edge tab or helper process."),
        ("mdworker", "A Spotlight worker indexing files right now."),
        ("com.apple.", "An Apple system service."),
    ]

    /// Best-effort description for a group (the app/daemon row).
    static func describe(name: String, path: String, kind: GroupKind) -> ProcInfo {
        let category: String
        switch kind {
        case .app: category = "Application"
        case .cli: category = "Command-line tool"
        case .daemon:
            category = path.contains("/System/") || path.contains("/usr/libexec") || path.hasPrefix("/sbin") || path.hasPrefix("/usr/sbin")
                ? "macOS system service" : "Background service"
        }
        let detail = lookup(name: name, path: path)
            ?? defaultDetail(category: category, kind: kind, path: path)
        return ProcInfo(title: name, category: category, detail: detail, path: path)
    }

    /// Description for a single child process (uses its row label).
    static func describe(label: String, path: String) -> ProcInfo {
        let base = (path as NSString).lastPathComponent
        let detail = lookup(name: base, path: path)
            ?? lookup(name: label, path: path)
            ?? "Part of its parent app."
        return ProcInfo(title: label, category: "Process", detail: detail, path: path)
    }

    private static func lookup(name: String, path: String) -> String? {
        if let d = known[name] { return d }
        let hay = name + " " + path
        for (needle, desc) in rules where hay.contains(needle) { return desc }
        return nil
    }

    private static func defaultDetail(category: String, kind: GroupKind, path: String) -> String {
        switch kind {
        case .app: return "A macOS application."
        case .cli: return "A program running in a terminal session."
        case .daemon:
            return category == "macOS system service"
                ? "A background service that's part of macOS."
                : "A background helper installed by an app or the system."
        }
    }

    /// A web search for anything the catalog doesn't explain.
    static func lookupURL(_ name: String) -> URL? {
        let q = "macOS process \(name) what is it"
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: q)]
        return c?.url
    }
}
