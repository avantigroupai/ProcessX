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
    static func isVisible(_ p: ProcSample) -> Bool { p.priority > Sampler.bgBand }

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
        var visibleCount: Int { renderers.filter(BrowserProcs.isVisible).count }
        var backgroundCount: Int { renderers.count - visibleCount }
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
        return b
    }
}
