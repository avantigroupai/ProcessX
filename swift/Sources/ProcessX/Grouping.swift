import Foundation

enum GroupKind: String { case app, cli, daemon }

struct ProcGroup: Identifiable {
    var key: String
    var name: String
    var kind: GroupKind
    /// For a terminal-hosted CLI: the key of the terminal app hosting it.
    var parentKey: String?
    var cpu: Double = 0
    var mem: UInt64 = 0
    var procs: [ProcSample] = []
    var isSystem: Bool = true
    var isCritical: Bool = false
    var id: String { key }

    var count: Int { procs.count }
    /// Processes the kernel currently has in the low-priority band — for ANY
    /// reason. Browsers park their own background tabs here, so this is NOT a
    /// count of what *we* throttled; that lives in ThrottleStore. Used only to
    /// detect drift, never to label a row "slowed".
    var inBackgroundBand: Int { procs.filter { $0.priority <= Sampler.bgBand }.count }
    var actionable: Bool { !isCritical && !isSystem }
}

struct Model {
    /// Reindexes itself on every assignment. `Monitor.tick` sorts this array
    /// *after* `build` returns, and an index built before that sort silently
    /// points every key at the wrong group — which is exactly how a cap ended up
    /// recorded against a different app than the one the menu was opened on.
    /// Keeping the index in a `didSet` makes that mistake unrepresentable.
    var groups: [ProcGroup] = [] { didSet { reindex() } }
    var byPID: [pid_t: ProcSample] = [:]
    var frontKey: String?
    /// The frontmost group plus every CLI group it hosts — precomputed, because
    /// `isFront` is asked once per row per redraw and once per *process* in the
    /// auto-tame pass. Resolving it by scanning `groups` made that a quadratic
    /// walk over the whole process table every two seconds.
    var frontKeys: Set<String> = []
    /// Key → index into `groups`, for the same reason.
    private(set) var indexByKey: [String: Int] = [:]

    private mutating func reindex() {
        indexByKey.removeAll(keepingCapacity: true)
        indexByKey.reserveCapacity(groups.count)
        for (i, g) in groups.enumerated() { indexByKey[g.key] = i }
    }

    /// A process is "in the foreground" if its group is frontmost, OR it's a
    /// terminal-hosted CLI whose host terminal is frontmost.
    ///
    /// Without the parentKey hop a `claude`/`cowork` session — the thing this app
    /// exists to tame — never registers as focused, because its group is c:<pid>
    /// while the frontmost app group is a:<Terminal>. That blind spot would both
    /// throttle a session you're actively using and break its focus rescue.
    func isFront(_ groupKey: String) -> Bool { frontKeys.contains(groupKey) }

    func group(for key: String) -> ProcGroup? {
        indexByKey[key].map { groups[$0] }
    }
}

enum Grouping {

    /// Safari's tab processes are XPC services reparented away from Safari, so they
    /// land in a daemon group named "com.apple.WebKit.WebContent". Say what it is.
    static func daemonName(_ base: String) -> String {
        switch base {
        case "com.apple.WebKit.WebContent": return "Web pages (Safari tabs)"
        case "com.apple.WebKit.GPU": return "Web pages (GPU)"
        case "com.apple.WebKit.Networking": return "Web pages (networking)"
        default: return base
        }
    }

    /// "/Applications/Foo.app/Contents/MacOS/Foo" -> "Foo"
    ///
    /// Scanned by hand rather than by regex. `build()` calls this once per
    /// ancestor per process — on a 900-process machine that was several thousand
    /// `NSRegularExpression` evaluations every two seconds, and it showed up in a
    /// profile as ICU regex matching inside the sampling tick. A literal scan for
    /// ".app/" does the same job with no allocation and no matcher.
    static func appName(of path: String) -> String? {
        // Leftmost ".app/", matching what the regex found. Everything between the
        // slash before it and the extension is the bundle name.
        guard let ext = path.range(of: ".app/") else { return nil }
        let before = path[path.startIndex..<ext.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let name = before[before.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    static func baseName(_ p: String) -> String {
        var b = (p as NSString).lastPathComponent
        if b.hasPrefix("-") { b.removeFirst() }                    // "-zsh" -> "zsh"
        return b
    }

    /// Group processes the way Activity Monitor does — one row per app, with all
    /// its helpers folded in — except that terminal-hosted CLI sessions get their
    /// own row instead of hiding inside "Terminal".
    static func build(procs: [ProcSample], frontPID: pid_t?, myUID: uid_t) -> Model {
        var byPID: [pid_t: ProcSample] = [:]
        for p in procs { byPID[p.pid] = p }

        var groups: [String: ProcGroup] = [:]
        var order: [String] = []
        var appNameCache: [String: String?] = [:]

        func assign(_ p: ProcSample, key: String, name: String, kind: GroupKind, parentKey: String?) {
            if groups[key] == nil {
                groups[key] = ProcGroup(key: key, name: name, kind: kind, parentKey: parentKey,
                                        isCritical: Policy.critical.contains(name))
                order.append(key)
            }
            groups[key]!.cpu += p.cpuPct
            groups[key]!.mem += p.rss
            if p.uid == myUID { groups[key]!.isSystem = false }
            var pp = p
            pp.groupKey = key
            groups[key]!.procs.append(pp)
            byPID[p.pid]!.groupKey = key
        }

        for p in procs where p.pid != 0 {
            // Walk up to (not including) launchd.
            var chain: [ProcSample] = [p]
            var cur = p
            var guardCount = 0
            while guardCount < 40, let parent = byPID[cur.ppid], parent.pid > 1, parent.pid != cur.pid {
                chain.append(parent)
                cur = parent
                guardCount += 1
            }

            // The app bundle closest to launchd owns the tree:
            // "Chrome Helper (Renderer)" belongs to "Google Chrome".
            // Siblings share ancestors, so the same paths come round again and
            // again within one build — memoise rather than re-parse.
            var appIdx: Int?
            var appAtIdx: String?
            for i in stride(from: chain.count - 1, through: 0, by: -1) {
                let path = chain[i].path
                let name: String?
                if let cached = appNameCache[path] { name = cached }
                else { name = appName(of: path); appNameCache[path] = name }
                if let name {
                    appIdx = i
                    appAtIdx = name
                    break
                }
            }

            if let ai = appIdx, let app = appAtIdx {
                if Policy.terminals.contains(app) {
                    // First non-shell process below the terminal is the session root.
                    var sessionIdx: Int?
                    for i in stride(from: ai - 1, through: 0, by: -1)
                    where !Policy.shells.contains(baseName(chain[i].path)) {
                        sessionIdx = i
                        break
                    }
                    if let si = sessionIdx {
                        assign(p, key: "c:\(chain[si].pid)", name: cliTitle(chain[si]),
                               kind: .cli, parentKey: "a:\(app)")
                        continue
                    }
                }
                assign(p, key: "a:\(app)", name: app, kind: .app, parentKey: nil)
            } else {
                let b = baseName(p.path)
                assign(p, key: "d:\(b)", name: daemonName(b), kind: .daemon, parentKey: nil)
            }
        }

        var frontKey: String?
        if let fp = frontPID, let fproc = byPID[fp] { frontKey = fproc.groupKey }

        var model = Model(byPID: byPID, frontKey: frontKey)
        model.groups = order.compactMap { groups[$0] }
        if let front = frontKey {
            model.frontKeys = [front]
            for g in model.groups where g.parentKey == front { model.frontKeys.insert(g.key) }
        }
        return model
    }

    /// "node" running "cli.js" reads as "node cli.js" rather than a bare "node".
    static func cliTitle(_ p: ProcSample) -> String {
        let b = baseName(p.path)
        return b
    }

    /// Row label for one process inside a group.
    static func label(_ p: ProcSample) -> String {
        let b = baseName(p.path)
        if p.path.contains("com.apple.WebKit.WebContent") { return "Web page (tab process)" }
        if p.path.contains("com.apple.WebKit.GPU") { return "Browser GPU process" }
        if p.path.contains("com.apple.WebKit.Networking") { return "Browser networking" }
        if b.hasSuffix("Helper (Renderer)") { return b + " — tab / page" }
        return b
    }
}
