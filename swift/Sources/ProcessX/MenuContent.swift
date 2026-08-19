import AppKit
import SwiftUI

// The menu-bar popover is read at a glance, so its whole type ramp and geometry
// scale up from the original compact base sizes by one factor. Bump `menuScale`
// to 2.0 for even larger text; every font, column width and padding follows.
private let menuScale: CGFloat = 1.7
private func ms(_ pt: CGFloat) -> CGFloat { (pt * menuScale).rounded() }

// Monochrome glyphs only — SF Symbols inherit the text colour, no coloured fills.
private extension Image {
    static func glyph(_ name: String) -> some View {
        Image(systemName: name).symbolRenderingMode(.monochrome)
    }
}

func fmtBytes(_ b: UInt64) -> String {
    let g = Double(b) / 1_073_741_824
    if g >= 1 { return String(format: g >= 10 ? "%.1f GB" : "%.2f GB", g) }
    return "\(b / 1_048_576) MB"
}

struct MenuContent: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tiles
            Divider()
            controls
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: ms(460))
    }

    private var header: some View {
        HStack(spacing: ms(8)) {
            Image.glyph("waveform.path.ecg").font(.system(size: ms(14)))
            Text("ProcessX").font(.system(size: ms(14), weight: .semibold))
            Spacer()
            // A cap suspends processes, so releasing one must always be reachable
            // from the menu bar — without needing to raise the main window.
            if !monitor.caps.isEmpty {
                Button {
                    monitor.clearAllCaps()
                } label: {
                    Label("Release caps (\(monitor.caps.count))", systemImage: "speedometer")
                }
                .buttonStyle(.bordered).controlSize(.large).font(.system(size: ms(11)))
                .help("Remove every hard CPU cap — capped apps stop being suspended.")
            }
            if !monitor.throttled.isEmpty {
                Button {
                    monitor.restoreAll()
                } label: {
                    Label("Restore all (\(monitor.throttled.count))", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered).controlSize(.large).font(.system(size: ms(11)))
            }
            Button {
                monitor.quickFast()
            } label: {
                Label("QuickFast", systemImage: "bolt.fill").symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).font(.system(size: ms(12), weight: .semibold))
            .help("Slow background hogs (Claude Desktop/Code, Cowork, other high-CPU background work) so the system stays snappy. Never touches the app you're using, protected system processes, or media/call apps. Fully reversible.")
        }
        .padding(.horizontal, ms(12)).padding(.vertical, ms(10))
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            Tile(icon: "cpu", label: "CPU",
                 value: monitor.menuBarTitle == "–" ? "–" : "\(String(format: "%.1f", monitor.totalCPU))%",
                 ratio: monitor.totalCPU / 100,
                 foot: "\(SystemStats.coreCount) cores")
            Divider().frame(height: ms(52))
            Tile(icon: "display", label: "GPU",
                 value: monitor.gpu.map { "\($0)%" } ?? "n/a",
                 ratio: Double(monitor.gpu ?? 0) / 100,
                 foot: "device")
            Divider().frame(height: ms(52))
            Tile(icon: "memorychip", label: "Memory",
                 value: fmtBytes(monitor.memory.used),
                 ratio: monitor.memory.total > 0 ? Double(monitor.memory.used) / Double(monitor.memory.total) : 0,
                 foot: monitor.memory.pressure == "normal" ? "pressure normal" : "pressure \(monitor.memory.pressure)",
                 alert: monitor.memory.pressure != "normal")
            Divider().frame(height: ms(52))
            Tile(icon: "tortoise", label: "Slowed",
                 value: "\(monitor.throttled.count)",
                 ratio: 0,
                 foot: monitor.throttled.isEmpty ? "none" : monitor.throttled.prefix(2).map(\.name).joined(separator: ", "))
        }
        .padding(.vertical, ms(8))
    }

    private var controls: some View {
        HStack(spacing: ms(10)) {
            HStack(spacing: ms(5)) {
                Image.glyph("magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter…", text: $monitor.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, ms(7)).padding(.vertical, ms(3))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: ms(6)))
            Toggle("System", isOn: $monitor.showSystem).toggleStyle(.checkbox)
            Toggle("Auto-tame", isOn: $monitor.autoTame).toggleStyle(.checkbox)
                .help("Automatically slow any background process that stays above \(Int(monitor.cpuThreshold))% of a core for ~6s (e.g. a greedy ffmpeg encode). Bringing it to the front restores it instantly.")
        }
        .font(.system(size: ms(11)))
        .padding(.horizontal, ms(12)).padding(.vertical, ms(7))
    }

    private var list: some View {
        ScrollView {
            // Plain VStack: the list is capped at 50 rows, so laziness buys nothing
            // and a lazy container won't materialise when rendered offscreen.
            VStack(spacing: 0) {
                ForEach(monitor.visibleGroups.prefix(50)) { g in
                    GroupRow(group: g, monitor: monitor)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(height: ms(210))
        // Same hold as the main window: the popover is smaller and the buttons
        // are closer together, so a row shifting under the cursor matters more.
        .onHover { monitor.hoverTable($0) }
    }

    private var footer: some View {
        HStack {
            Text(monitor.lastMessage ?? "Slowing uses the macOS background band — reversible, no admin rights.")
                .font(.system(size: ms(10))).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: ms(10))).foregroundStyle(.secondary)
        }
        .padding(.horizontal, ms(12)).padding(.vertical, ms(7))
    }
}

private struct Tile: View {
    var icon: String
    var label: String
    var value: String
    var ratio: Double
    var foot: String
    var alert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: ms(3)) {
            HStack(spacing: ms(4)) {
                Image.glyph(icon).font(.system(size: ms(9))).foregroundStyle(.secondary)
                Text(label).font(.system(size: ms(10))).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: ms(17), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Meter(ratio: ratio).opacity(ratio > 0 ? 1 : 0)
            HStack(spacing: ms(3)) {
                if alert { Image.glyph("exclamationmark.triangle").font(.system(size: ms(8))) }
                Text(foot).font(.system(size: ms(9))).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ms(10))
    }
}

struct GroupRow: View {
    var group: ProcGroup
    @ObservedObject var monitor: Monitor
    @State private var expanded = false
    @State private var hovering = false

    /// How many of this group's processes *we* put in the background band.
    private var ourThrottled: Int { group.procs.filter { monitor.isThrottledByUs($0.pid) }.count }
    private var capRecord: CapRecord? { monitor.cap(forKey: group.key) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ms(7)) {
                Button {
                    expanded.toggle()
                } label: {
                    Image.glyph("chevron.right")
                        .font(.system(size: ms(8)))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: ms(10))
                }
                .buttonStyle(.plain)
                .opacity(group.count > 1 ? 1 : 0)
                .disabled(group.count <= 1)

                Image.glyph(icon).font(.system(size: ms(10))).foregroundStyle(.secondary).frame(width: ms(12))
                Text(group.name).font(.system(size: ms(12), weight: .medium)).lineLimit(1)
                if group.count > 1 {
                    Text("×\(group.count)").font(.system(size: ms(10))).foregroundStyle(.secondary)
                }
                if monitor.model.isFront(group.key) { Chip(text: "active app") }
                // "slowed" means WE slowed it. The kernel band alone would light up
                // every browser's own backgrounded tabs and offer a dead Restore.
                if ourThrottled > 0 { Chip(text: ourThrottled == group.count ? "slowed" : "\(ourThrottled) slowed") }
                if let c = capRecord { Chip(text: "capped \(Int(c.percent))%") }

                Spacer(minLength: ms(4))
                Text(String(format: "%.1f%%", group.cpu))
                    .font(.system(size: ms(11), design: .rounded)).monospacedDigit()
                    .frame(width: ms(48), alignment: .trailing)
                Text(fmtBytes(group.mem))
                    .font(.system(size: ms(11))).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: ms(58), alignment: .trailing)
                actions.frame(width: ms(78), alignment: .trailing)
            }
            .padding(.horizontal, ms(12)).padding(.vertical, ms(5))
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }

            if expanded {
                if monitor.isBrowser(group) {
                    browserTabs
                } else {
                    ForEach(group.procs.sorted { $0.cpuPct > $1.cpuPct }.prefix(12), id: \.pid) { p in
                        ChildRow(proc: p, monitor: monitor)
                    }
                }
            }
        }
        .onChange(of: expanded) { _, now in
            if now, monitor.isBrowser(group) { monitor.refreshTabs(group.name) }
        }
    }

    private var icon: String {
        switch group.kind {
        case .app: return "app"
        case .cli: return "terminal"
        case .daemon: return "gearshape"
        }
    }

    // Real browser tabs (name + jump), same source as the main window.
    @ViewBuilder private var browserTabs: some View {
        if monitor.tabsNotPermitted.contains(group.name) {
            HStack(spacing: ms(5)) {
                Image.glyph("lock.shield").font(.system(size: ms(9))).foregroundStyle(.secondary)
                Text("Allow control of \(group.name) to list tabs").font(.system(size: ms(10))).foregroundStyle(.secondary)
                Button("Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.plain).font(.system(size: ms(9))).foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.leading, ms(34)).padding(.trailing, ms(12)).padding(.vertical, ms(4))
            .background(Color.primary.opacity(0.03))
        } else if let tabs = monitor.browserTabs[group.name] {
            if tabs.isEmpty {
                menuInfoRow("No open tabs")
            } else {
                ForEach(tabs) { tab in MenuTabRow(tab: tab, appName: group.name, monitor: monitor) }
            }
        } else {
            menuInfoRow("Reading tabs…")
        }
    }

    private func menuInfoRow(_ text: String) -> some View {
        Text(text).font(.system(size: ms(10))).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ms(34)).padding(.vertical, ms(4))
            .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var actions: some View {
        if group.isCritical || !group.actionable {
            HStack(spacing: ms(3)) {
                Image.glyph("lock").font(.system(size: ms(9)))
                Text("protected").font(.system(size: ms(9)))
            }
            .foregroundStyle(.tertiary)
            .help("Protected — slowing this would hurt system stability")
        } else if capRecord != nil {
            // Caps are set from the main window; the menu only ever releases one.
            Button("Uncap") { monitor.clearCap(group) }
                .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
                .help("Stop suspending \(group.name) — it runs at full speed again")
        } else if ourThrottled > 0 {
            Button("Restore") { monitor.restoreGroup(group) }
                .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
        } else {
            Button("Slow down") { monitor.throttleGroup(group) }
                .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
        }
    }
}

private struct MenuTabRow: View {
    var tab: BrowserTab
    var appName: String
    @ObservedObject var monitor: Monitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ms(6)) {
            Image.glyph("globe").font(.system(size: ms(10))).foregroundStyle(.secondary)
            Text(tab.title.isEmpty ? "Untitled" : tab.title).font(.system(size: ms(11))).lineLimit(1)
            if tab.active { Chip(text: "frontmost") }
            Spacer(minLength: ms(4))
            Button { monitor.jumpToTab(tab, appName: appName) } label: {
                Label("Jump", systemImage: "arrow.up.forward")
            }
            .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.leading, ms(34)).padding(.trailing, ms(12)).padding(.vertical, ms(4))
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { monitor.jumpToTab(tab, appName: appName) }
        .help("Double-click to switch to this tab")
    }
}

private struct ChildRow: View {
    var proc: ProcSample
    @ObservedObject var monitor: Monitor

    var body: some View {
        HStack(spacing: ms(7)) {
            Text(Grouping.label(proc)).font(.system(size: ms(11))).foregroundStyle(.secondary).lineLimit(1)
            Text(verbatim: "\(proc.pid)").font(.system(size: ms(9))).foregroundStyle(.tertiary).monospacedDigit()
            if monitor.isThrottledByUs(proc.pid) {
                Chip(text: monitor.origin(proc.pid) == .auto ? "auto-slowed" : "slowed")
            } else if proc.priority <= Sampler.bgBand {
                // Informational: it's in the band, but it put itself there.
                Chip(text: "bg (self)")
            }
            Spacer(minLength: ms(4))
            Text(String(format: "%.1f%%", proc.cpuPct))
                .font(.system(size: ms(10), design: .rounded)).monospacedDigit()
                .frame(width: ms(44), alignment: .trailing)
            Text(fmtBytes(proc.rss))
                .font(.system(size: ms(10))).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: ms(54), alignment: .trailing)
            Group {
                if monitor.isThrottledByUs(proc.pid) {
                    Button("Restore") { monitor.restore(pids: [proc.pid]) }
                        .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
                } else {
                    Button("Slow") { monitor.throttle(pids: [proc.pid], origin: .manual, manual: true) }
                        .buttonStyle(.bordered).controlSize(.regular).font(.system(size: ms(10)))
                }
            }
            .frame(width: ms(78), alignment: .trailing)
        }
        .padding(.leading, ms(34)).padding(.trailing, ms(12)).padding(.vertical, ms(3))
        .background(Color.primary.opacity(0.03))
    }
}

/// Drawn rather than using a linear ProgressView: exact control over the severity
/// colour, and it renders in every context (an NSView-backed bar does not).
private struct Meter: View {
    var ratio: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(ratio > 0.85 ? Color.red : ratio > 0.6 ? Color.orange : Color.accentColor)
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
            }
        }
        .frame(height: ms(3))
    }
}

private struct Chip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: ms(8), weight: .semibold))
            .padding(.horizontal, ms(5)).padding(.vertical, ms(1))
            .background(.quaternary, in: Capsule())
    }
}
