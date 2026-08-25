import Foundation

/// The per-process side of a browser row.
///
/// macOS will not tell us which tab a renderer is serving — that mapping lives
/// only inside the browser, and no public API exports it (see BrowserTabs). So
/// the honest thing to show next to the named-but-numberless tab list is the
/// numbered-but-nameless renderer list: real CPU and memory per renderer, with
/// no claim about which tab it belongs to.
///
/// Two facts keep that from being useless:
///
///  * A renderer serving a tab you can actually see sits at normal scheduling
///    priority; the browser parks renderers for hidden tabs in the background
///    band. So "visible" narrows a hot renderer down to the handful of tabs on
///    screen, which is usually the answer you wanted.
///  * Renderers are shared. Chrome puts same-site tabs in one process, so the
///    renderer count runs well below the tab count and one row can legitimately
///    account for several tabs.
enum BrowserProcs {

    enum Role {
        case renderer     // a page/tab process — the interesting one
        case support      // GPU, networking, utility, plugin, the browser process itself
    }

    /// Chromium names its child bundles "… Helper (Renderer)". WebKit gives its
    /// page processes their own XPC service name. Anything else in the tree is
    /// support: the browser process, GPU, networking, extensions, utilities.
    static func role(of p: ProcSample) -> Role {
        let path = p.path
        if path.contains("Helper (Renderer)") { return .renderer }
        if path.contains("com.apple.WebKit.WebContent") { return .renderer }
        return .support
    }

    /// A renderer's kernel priority is the one honest hint we get about whether
    /// its tab is on screen. Browsers demote hidden tabs into the background
    /// band themselves — measured as pti_priority 4, against ~26–47 for a
    /// normal task and higher still for one driving media.
    ///
    /// It is a hint and not an answer: Chrome demotes a hidden tab's renderer
    /// lazily, so a renderer above the band may be serving a tab that left the
    /// screen minutes ago. Measured here: 13 renderers above the band against 4
    /// tabs actually on screen. Above the band means "not parked", not "on
    /// screen", and nothing in the UI may claim otherwise.
    static func isVisible(_ p: ProcSample) -> Bool { p.priority > Sampler.bgBand }

    /// Chromium runs extensions in renderer processes too — same bundle, same
    /// "Helper (Renderer)" name — and they serve no tab at all. On this machine
    /// they were 13 of 36 "renderers", every one of them previously labelled a
    /// tab. The launch arguments are the only thing that tells them apart.
    static let extensionFlag = "--extension-process"

    static func isExtension(_ p: ProcSample) -> Bool {
        ProcArgs.hasFlag(extensionFlag, pid: p.pid, startedAt: p.startedAt)
    }

    /// What a renderer row is allowed to call itself.
    ///
    /// The PID → tab mapping doesn't exist (see BrowserTabs), so this never
    /// claims one. What the browser does tell us is which tabs are on screen —
    /// the active tab of each window — and a renderer outside the background
    /// band is serving one of those. When exactly one tab is on screen there is
    /// nothing left to choose between, so we print the name; when there are
    /// several, the shortlist is the whole truth and the row says so.
    ///
    /// The hedge that survives even the single-tab case: a hidden tab playing
    /// media also sits above the background band. So this is "almost certainly",
    /// not "is" — the tooltip carries that caveat, the row stays readable.
    enum OnScreen: Equatable {
        case unknown            // tabs not read yet, none on screen, or not ours to name
        case one(String)        // a single tab is on screen — name it
        case several([String])  // the shortlist, in window order
    }

    /// What a single visible renderer row may print.
    enum RowName: Equatable {
        case none            // nothing honest to say
        case name(String)    // one tab on screen, one renderer that can be serving it
        case maybe(String)   // one tab on screen, several candidates for it
        case oneOf(Int)      // this row is one of the tabs on screen — which one is unknowable
    }

    /// The arithmetic that decides how hard a row is allowed to claim.
    ///
    /// `visibleRenderers` is how many tab renderers sit above the background
    /// band. If that outnumbers the tabs on screen, most of those rows are not
    /// serving an on-screen tab at all, and "one of the 4 on screen" would be
    /// false on the majority of them — so the row says nothing and the names go
    /// in the section line above, where they claim nothing about any one row.
    static func rowName(onScreen: OnScreen, visibleRenderers: Int) -> RowName {
        switch onScreen {
        case .unknown:
            return .none
        case .one(let title):
            return visibleRenderers <= 1 ? .name(title) : .maybe(title)
        case .several(let titles):
            return visibleRenderers <= titles.count ? .oneOf(titles.count) : .none
        }
    }

    /// - Parameter shared: WebKit page processes are shared with every app that
    ///   shows web content, so a Safari tab title can't be pinned to one of them
    ///   at all — those rows stay nameless.
    static func onScreen(tabs: [BrowserTab]?, shared: Bool) -> OnScreen {
        guard !shared, let tabs else { return .unknown }
        let front = tabs.filter(\.active).map(\.displayName)
        switch front.count {
        case 0:  return .unknown
        case 1:  return .one(front[0])
        default: return .several(front)
        }
    }

    struct Breakdown {
        var renderers: [ProcSample] = []      // sorted by CPU, descending
        var supportCount: Int = 0
        var supportCPU: Double = 0
        var supportMem: UInt64 = 0
        /// WebKit page processes are reparented to launchd and shared by every
        /// app that shows web content, so they can't be attributed to Safari
        /// alone. The UI has to say so rather than imply these are all Safari's.
        var shared: Bool = false

        var rendererCPU: Double { renderers.reduce(0) { $0 + $1.cpuPct } }
        var rendererMem: UInt64 { renderers.reduce(0) { $0 + $1.rss } }
        /// Renderers that host an extension rather than a page. Kept in
        /// `renderers` so a hot extension still shows up in the CPU-sorted list —
        /// it is exactly the kind of process this app exists to find — but never
        /// counted as, or named after, a tab.
        var extensionPIDs: Set<pid_t> = []

        var tabRenderers: [ProcSample] { renderers.filter { !extensionPIDs.contains($0.pid) } }
        var extensionCount: Int { extensionPIDs.count }
        var visibleCount: Int { tabRenderers.filter(BrowserProcs.isVisible).count }
        var backgroundCount: Int { tabRenderers.count - visibleCount }
        var isEmpty: Bool { renderers.isEmpty && supportCount == 0 }
    }

    /// WebKit's page processes live here once launchd adopts them — the same
    /// group Grouping.daemonName relabels as "Web pages (Safari tabs)".
    static let webKitContentKey = "d:com.apple.WebKit.WebContent"

    /// Split a browser group's processes into renderers and everything else.
    ///
    /// For Chromium the helpers are genuine children of the browser, so the
    /// attribution is exact. For Safari the page processes aren't in the group
    /// at all — they're reparented to launchd — so we reach into the WebKit
    /// daemon group and flag the result as shared.
    static func breakdown(for group: ProcGroup, model: Model) -> Breakdown {
        var b = Breakdown()

        for p in group.procs {
            switch role(of: p) {
            case .renderer:
                b.renderers.append(p)
            case .support:
                b.supportCount += 1
                b.supportCPU += p.cpuPct
                b.supportMem += p.rss
            }
        }

        if b.renderers.isEmpty, BrowserTabs.engine(for: group.name) == .safari,
           let webKit = model.group(for: webKitContentKey) {
            b.renderers = webKit.procs
            b.shared = true
        }

        b.renderers.sort { $0.cpuPct > $1.cpuPct }
        // Chromium only: WebKit hosts Safari's extensions in the same shared
        // WebContent pool, with no argument that separates them.
        if !b.shared, BrowserTabs.engine(for: group.name) == .chromium {
            b.extensionPIDs = Set(b.renderers.filter(isExtension).map(\.pid))
        }
        return b
    }
}
