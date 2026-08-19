import AppKit
import SwiftUI

enum UI {
    static let hero: CGFloat = 34
    static let title: CGFloat = 26
    static let body: CGFloat = 16
    static let row: CGFloat = 18
    static let num: CGFloat = 16
    static let caption: CGFloat = 13
    static let chip: CGFloat = 11
    static let rowHeight: CGFloat = 46
    static let gutter: CGFloat = 24
    static let cardRadius: CGFloat = 24
}

private func glyph(_ name: String, _ size: CGFloat) -> some View {
    Image(systemName: name).symbolRenderingMode(.monochrome).font(.system(size: size))
}

/// Version + build stamp, read from the bundle's Info.plist. `bundle.sh` stamps
/// CFBundleVersion with the build timestamp, so this string changes every build —
/// a subtle way to confirm you're running the latest one.
enum AppInfo {
    static let version: String = {
        let d = Bundle.main.infoDictionary
        let short = d?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = d?["CFBundleVersion"] as? String ?? "—"
        return "v\(short) · \(build)"
    }()
}

struct MainWindow: View {
    @ObservedObject var monitor: Monitor

    private var theme: AppTheme { monitor.theme }

    var body: some View {
        VStack(spacing: UI.gutter) {
            header
            gauges.frame(height: 232).padding(.horizontal, UI.gutter)
            controls.padding(.horizontal, UI.gutter)
            processTable
                .padding(.horizontal, UI.gutter)
                .padding(.bottom, UI.gutter)
        }
        .background(ThemeBackground(theme: theme))
        .tint(theme.accent)
        .preferredColorScheme(theme.forcedScheme)
        .frame(minWidth: 980, minHeight: 660)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            glyph("waveform.path.ecg", 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("ProcessX").font(.system(size: UI.title, weight: .semibold))
                HStack(spacing: 6) {
                    Text("macOS process & priority monitor")
                        .font(.system(size: UI.caption)).foregroundStyle(.secondary)
                    Text(AppInfo.version)
                        .font(.system(size: UI.chip, design: .monospaced)).foregroundStyle(.tertiary)
                        .help("Version and build stamp — check this matches the build you expect.")
                }
            }
            Spacer()

            themeMenu

            if !monitor.caps.isEmpty {
                Button { monitor.clearAllCaps() } label: {
                    Label("Release caps (\(monitor.caps.count))", systemImage: "speedometer")
                        .font(.system(size: UI.body, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .help("Remove every hard CPU cap — capped apps stop being suspended and run at full speed.")
            }

            if !monitor.throttled.isEmpty {
                Button { monitor.restoreAll() } label: {
                    Label("Restore all (\(monitor.throttled.count))", systemImage: "arrow.uturn.backward")
                        .font(.system(size: UI.body, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }

            Button { monitor.quickFast() } label: {
                Label("QuickFast", systemImage: "bolt.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: UI.body, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.glassProminent)
            // Kill the system focus ring: .glassProminent makes this the window's
            // default control, so macOS draws an accent-coloured focus ring around
            // it (in the user's *System Settings* accent — green here), which reads
            // as a stray border on the glass. The button stays fully clickable.
            .focusEffectDisabled()
            .help("Slow background hogs (Claude Desktop/Code, Cowork, other high-CPU background work) so the system stays snappy. Never touches the app you're using, protected system processes, or media/call apps. Fully reversible.")
        }
        .padding(.horizontal, UI.gutter)
        .padding(.top, 20)
    }

    private var themeMenu: some View {
        Menu {
            Picker("Theme", selection: $monitor.themeName) {
                ForEach(AppTheme.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(theme.rawValue, systemImage: theme.symbol)
                .font(.system(size: UI.caption, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(.regularMaterial, in: .capsule)
        .help("Change the look")
    }

    // MARK: gauges

    private var gauges: some View {
        // Fixed height + top alignment so every card fills the same box and their
        // internal rows line up — no card can end up shorter than its neighbours.
        HStack(alignment: .top, spacing: 18) {
            GaugeCard(theme: theme, icon: "cpu", label: "CPU",
                      progress: monitor.totalCPU / 100,
                      big: monitor.cpuHistory.isEmpty ? "–" : String(format: "%.0f", monitor.totalCPU),
                      unit: "%", foot: "\(SystemStats.coreCount) cores active",
                      history: monitor.cpuHistory)
            GaugeCard(theme: theme, icon: "display", label: "GPU",
                      progress: Double(monitor.gpu ?? 0) / 100,
                      big: monitor.gpu.map(String.init) ?? "n/a",
                      unit: monitor.gpu == nil ? "" : "%", foot: "device utilization",
                      history: monitor.gpuHistory)
            GaugeCard(theme: theme, icon: "memorychip", label: "Memory",
                      progress: monitor.memory.total > 0
                        ? Double(monitor.memory.used) / Double(monitor.memory.total) : 0,
                      big: memNumber, unit: memUnit,
                      foot: monitor.memory.pressure == "normal"
                        ? "of \(fmtBytes(monitor.memory.total))"
                        : "pressure \(monitor.memory.pressure)",
                      alert: monitor.memory.pressure != "normal",
                      history: [])
            CountCard(theme: theme, icon: "tortoise", label: "Slowed down",
                      count: monitor.throttled.count,
                      foot: tamedFoot)
        }
    }

    /// One line for two mechanisms: caps are rarer and more consequential, so they
    /// take the line whenever any exist.
    private var tamedFoot: String {
        if let c = monitor.caps.first {
            let extra = monitor.caps.count > 1 ? " +\(monitor.caps.count - 1) more" : ""
            return "capped: \(c.name) at \(Int(c.percent))%\(extra)"
        }
        return monitor.throttled.isEmpty
            ? "nothing throttled by ProcessX"
            : Array(Set(monitor.throttled.map(\.name))).sorted().prefix(2).joined(separator: ", ")
    }

    private var memNumber: String {
        let g = Double(monitor.memory.used) / 1_073_741_824
        return String(format: g >= 10 ? "%.0f" : "%.1f", g)
    }
    private var memUnit: String { "GB" }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                glyph("magnifyingglass", UI.body).foregroundStyle(.secondary)
                TextField("Filter apps & processes…", text: $monitor.search)
                    .textFieldStyle(.plain).font(.system(size: UI.body))
                if !monitor.search.isEmpty {
                    Button { monitor.search = "" } label: {
                        glyph("xmark.circle.fill", UI.body).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: 360)
            .themedCard(theme, radius: 12)

            Toggle("System", isOn: $monitor.showSystem).toggleStyle(.switch).font(.system(size: UI.caption))
            Toggle("Auto-tame", isOn: $monitor.autoTame).toggleStyle(.switch).font(.system(size: UI.caption))
                .help("Automatically slow any background process that stays above \(Int(monitor.cpuThreshold))% of a core for ~6–8s (e.g. a greedy ffmpeg encode). Bringing it to the front restores it instantly.")

            Spacer()
            Text(monitor.lastMessage ?? "\(monitor.visibleGroups.count) apps")
                .font(.system(size: UI.caption)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
        }
    }

    // MARK: table

    private var processTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortHeader("APP / PROCESS", .name, width: nil, trailing: false)
                sortHeader("CPU", .cpu, width: 180, trailing: true)
                sortHeader("MEMORY", .memory, width: 100, trailing: true)
                sortHeader("PRIORITY", .priority, width: 110, trailing: false, leadingPad: 22)
                orderIndicator.frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)

            Divider().opacity(0.5)

            if monitor.visibleGroups.isEmpty {
                Text(monitor.search.isEmpty ? "Sampling…" : "Nothing matches.")
                    .font(.system(size: UI.body)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.visibleGroups.prefix(60)) { g in
                            BigGroupRow(group: g, monitor: monitor, accent: theme.accent)
                            Divider().opacity(0.28)
                        }
                    }
                }
                // Reaching for a button is enough to say "stop moving things".
                // No click, no mode to remember — the order holds the moment the
                // pointer arrives and resumes when it leaves.
                .onHover { monitor.hoverTable($0) }
            }
        }
        .frame(maxHeight: .infinity)
        .themedCard(theme, radius: UI.cardRadius)
    }

    /// Says whether rows are re-ranking or being held, and lets the hold be
    /// pinned — otherwise moving the pointer away to read something re-sorts the
    /// list and loses the row you had picked out.
    private var orderIndicator: some View {
        Button { monitor.togglePin() } label: {
            HStack(spacing: 5) {
                glyph(monitor.orderPinned ? "pin.fill"
                      : (monitor.orderFrozen ? "pause.fill" : "arrow.up.arrow.down"), 9)
                Text(monitor.orderPinned ? "pinned" : (monitor.orderFrozen ? "held" : "live"))
                    .font(.system(size: UI.chip, weight: .semibold)).tracking(0.6)
            }
            .foregroundStyle(monitor.orderFrozen ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
        .help(monitor.orderPinned
              ? "Row order is pinned. Click to let it re-rank live again."
              : "Rows re-rank as CPU changes, and hold still while the pointer is over the list so a button can't move out from under your click. Click to pin the order.")
    }

    // Activity-Monitor-style column header: click to sort by this column, click
    // again to flip direction. The active column is accent-tinted and shows an
    // up/down arrow; inactive columns reserve the arrow's width so titles never
    // shift when the sort changes.
    @ViewBuilder
    private func sortHeader(_ title: String, _ key: Monitor.SortKey,
                            width: CGFloat?, trailing: Bool, leadingPad: CGFloat = 0) -> some View {
        let active = monitor.sort == key
        let label = HStack(spacing: 4) {
            if trailing { Spacer(minLength: 0) }
            Text(title)
            glyph(monitor.sortAscending ? "chevron.up" : "chevron.down", 9).opacity(active ? 1 : 0)
            if !trailing { Spacer(minLength: 0) }
        }
        .font(.system(size: UI.chip, weight: .semibold)).tracking(0.6)
        .foregroundStyle(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))

        Button { monitor.setSort(key) } label: {
            Group {
                if let width {
                    label.frame(width: width, alignment: trailing ? .trailing : .leading)
                        .padding(.leading, leadingPad)
                } else {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
        .help("Sort by \(title.lowercased()) — click again to reverse")
    }
}

// MARK: - radial gauge

struct RadialGauge: View {
    var progress: Double
    var accent: Color
    var accent2: Color
    var track: Color
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [accent, accent2, accent]),
                                    center: .center,
                                    startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: progress)
        }
    }
}

private struct GaugeCard: View {
    var theme: AppTheme
    var icon: String
    var label: String
    var progress: Double
    var big: String
    var unit: String
    var foot: String
    var alert: Bool = false
    var history: [Double]

    // Match the ring exactly: brand accent until critical (>85%), then red. A
    // separate orange band here made the sparkline disagree with its own ring.
    private var severity: Color {
        progress > 0.85 ? .red : theme.accent
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                glyph(icon, UI.caption).foregroundStyle(.secondary)
                Text(label).font(.system(size: UI.caption, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if alert { glyph("exclamationmark.triangle.fill", UI.caption).foregroundStyle(.orange) }
            }
            ZStack {
                RadialGauge(progress: progress,
                            accent: progress > 0.85 ? .red : theme.accent,
                            accent2: progress > 0.85 ? .orange : theme.accent2,
                            track: theme.gaugeTrack)
                    .frame(width: 116, height: 116)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(big).font(.system(size: UI.hero, weight: .semibold))
                        .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    Text(unit).font(.system(size: UI.body, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
            }
            // Always reserve the sparkline row so Memory (which has no history to
            // plot) is exactly as tall as CPU/GPU. Otherwise it renders ~26px short.
            Group {
                if history.count > 1 {
                    Sparkline(values: history, color: severity)
                } else {
                    Color.clear
                }
            }
            .frame(height: 26)
            Text(foot).font(.system(size: UI.chip)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 16)
        .themedCard(theme, radius: UI.cardRadius)
    }
}

private struct CountCard: View {
    var theme: AppTheme
    var icon: String
    var label: String
    var count: Int
    var foot: String

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                glyph(icon, UI.caption).foregroundStyle(.secondary)
                Text(label).font(.system(size: UI.caption, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            ZStack {
                Circle().stroke(theme.gaugeTrack, lineWidth: 11).frame(width: 116, height: 116)
                    .opacity(count > 0 ? 1 : 0.5)
                if count > 0 {
                    Circle().stroke(theme.accent.opacity(0.5), lineWidth: 11).frame(width: 116, height: 116)
                }
                Text("\(count)").font(.system(size: UI.hero + 4, weight: .semibold)).monospacedDigit()
            }
            Spacer().frame(height: 26)
            Text(foot).font(.system(size: UI.chip)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 16)
        .themedCard(theme, radius: UI.cardRadius)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) / CGFloat(max(values.count - 1, 1)) * w,
                        y: h - CGFloat(min(v, maxV) / maxV) * (h - 2) - 1)
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: h)); pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: h)); p.closeSubpath()
                }.fill(color.opacity(0.12))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - rows

struct BigGroupRow: View {
    var group: ProcGroup
    @ObservedObject var monitor: Monitor
    var accent: Color
    /// Opens the row on first draw. Only `--render` sets this: ImageRenderer never
    /// delivers the click that would otherwise expand a row, so without it the
    /// headless preview can only ever show collapsed rows.
    var startExpanded = false
    /// nil until the disclosure is actually clicked — which is what lets
    /// `startExpanded` supply the initial value without a custom init.
    @State private var toggledOpen: Bool?
    private var expanded: Bool { toggledOpen ?? startExpanded }
    @State private var hovering = false
    @State private var confirmBulk = false
    @State private var showInfo = false
    /// Set when a cap was chosen but the one-time explainer hasn't been accepted.
    @State private var pendingCap: Double?

    private var ourThrottled: Int { group.procs.filter { monitor.isThrottledByUs($0.pid) }.count }
    private var capRecord: CapRecord? { monitor.cap(forKey: group.key) }

    private var info: ProcInfo {
        ProcessCatalog.describe(name: group.name, path: group.procs.first?.path ?? "", kind: group.kind)
    }
    private var rowTooltip: String {
        "\(info.title) — \(info.category)\n\(info.detail)"
        + (group.count > 1 ? "\n\(group.count) processes" : "")
        + (capRecord.map {
            String(format: "\nCapped at %d%% of a core — currently %.1f%%", Int($0.percent), $0.achieved)
        } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 11) {
                    Button { toggledOpen = !expanded } label: {
                        glyph("chevron.right", 11)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary).frame(width: 14)
                    }
                    .buttonStyle(.plain).opacity(group.count > 1 ? 1 : 0).disabled(group.count <= 1)

                    glyph(kindIcon, UI.body).foregroundStyle(.secondary).frame(width: 18)
                    Text(group.name).font(.system(size: UI.row, weight: .medium)).lineLimit(1)
                    if group.count > 1 {
                        Text("×\(group.count)").font(.system(size: UI.caption)).foregroundStyle(.secondary)
                    }
                    if monitor.model.isFront(group.key) { Pill(text: "active app", tone: .green, accent: accent) }
                    if ourThrottled > 0 {
                        Pill(text: ourThrottled == group.count ? "slowed" : "\(ourThrottled) slowed", tone: .accent, accent: accent)
                    }
                    if let c = capRecord {
                        Pill(text: "capped \(Int(c.percent))%", tone: .warn, accent: accent)
                    }
                    Button { showInfo = true } label: {
                        glyph("info.circle", UI.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || showInfo ? 1 : 0)
                    .help("What is this?")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        ProcessInfoCard(info: info, count: group.count)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CPUCell(pct: group.cpu, accent: accent).frame(width: 180, alignment: .trailing)
                Text(fmtBytes(group.mem)).font(.system(size: UI.num)).monospacedDigit()
                    .frame(width: 100, alignment: .trailing)
                priorityCell.frame(width: 110, alignment: .leading).padding(.leading, 22)
                actions.frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 22).frame(height: UI.rowHeight)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .onHover { hovering = $0 }
            .help(rowTooltip)

            if expanded {
                if monitor.isBrowser(group) {
                    browserDetail
                } else {
                    ForEach(group.procs.sorted { $0.cpuPct > $1.cpuPct }.prefix(15), id: \.pid) { p in
                        BigChildRow(proc: p, monitor: monitor, accent: accent)
                    }
                }
            }
        }
        .onChange(of: expanded) { _, now in
            if now, monitor.isBrowser(group) { monitor.refreshTabs(group.name) }
        }
        .confirmationDialog("Slow down all \(group.count) \(group.name) processes?",
                            isPresented: $confirmBulk, titleVisibility: .visible) {
            Button("Slow down \(group.count) processes") {
                monitor.throttleGroup(group)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves every process in \(group.name) into the background band. Reversible with Restore.")
        }
        // Shown once, before the first cap of the session's lifetime: a cap is a
        // different bargain from Slow down and the user has to be told which one
        // they're taking.
        .confirmationDialog("Cap \(group.name) at \(Int(pendingCap ?? 0))% of a core?",
                            isPresented: Binding(get: { pendingCap != nil },
                                                 set: { if !$0 { pendingCap = nil } }),
                            titleVisibility: .visible) {
            Button("Cap it") {
                if let p = pendingCap {
                    monitor.capAcknowledged = true
                    monitor.setCap(group, percent: p)
                }
                pendingCap = nil
            }
            Button("Cancel", role: .cancel) { pendingCap = nil }
        } message: {
            Text("""
                 A cap works differently from Slow down. Instead of changing scheduling \
                 priority, ProcessX repeatedly suspends and resumes the app to hold it \
                 under the percentage.

                 While suspended it cannot respond: network connections can time out, \
                 timers drift, and the app may beachball if it's on screen. Media and \
                 call apps, system processes and the app you're using are never capped, \
                 and bringing a capped app to the front releases the cap instantly.
                 """)
        }
    }

    private var kindIcon: String {
        switch group.kind {
        case .app: return "app.dashed"
        case .cli: return "terminal"
        case .daemon: return "gearshape"
        }
    }

    @ViewBuilder private var priorityCell: some View {
        if let c = capRecord {
            VStack(alignment: .leading, spacing: 1) {
                Pill(text: "cap \(Int(c.percent))%", tone: .warn, accent: accent)
                Text(String(format: "at %.1f%%", c.achieved))
                    .font(.system(size: UI.chip)).monospacedDigit().foregroundStyle(.tertiary)
            }
        } else if ourThrottled > 0 && ourThrottled == group.count {
            Pill(text: "background", tone: .accent, accent: accent)
        } else if ourThrottled > 0 {
            Pill(text: "mixed", tone: .neutral, accent: accent)
        } else {
            Text("normal").font(.system(size: UI.caption)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if group.isCritical || !group.actionable {
            HStack(spacing: 5) {
                glyph("lock", UI.chip); Text("protected").font(.system(size: UI.chip))
            }
            .foregroundStyle(.tertiary)
            .help("Protected — slowing this would hurt system stability")
        } else {
            HStack(spacing: 6) {
                if ourThrottled > 0 {
                    Button("Restore") { monitor.restoreGroup(group) }
                        .buttonStyle(.glass).font(.system(size: UI.caption))
                } else {
                    Button("Slow down") {
                        // Big apps (a browser is 90+ helpers) get a confirm so a stray
                        // click can't silently background a whole tree.
                        if group.count > 8 { confirmBulk = true } else { monitor.throttleGroup(group) }
                    }
                    .buttonStyle(.glass).font(.system(size: UI.caption))
                }
                capMenu
            }
        }
    }

    /// The hard cap lives behind a menu rather than a button: it's the sharper
    /// tool of the two and shouldn't be one stray click away.
    private var capMenu: some View {
        Menu {
            if let c = capRecord {
                Text(String(format: "Capped at %d%% — currently %.1f%%", Int(c.percent), c.achieved))
                Button("Remove cap") { monitor.clearCap(group) }
                Divider()
            }
            ForEach(Monitor.capChoices, id: \.self) { pct in
                Button("Cap at \(Int(pct))% of a core") { requestCap(pct) }
            }
            if let why = monitor.capRefusal(group) {
                Divider()
                Text("Can't cap — \(why)")
            }
        } label: {
            glyph("speedometer", UI.body).foregroundStyle(capRecord == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(capRecord == nil && monitor.capRefusal(group) != nil)
        .help("Hard CPU cap — holds \(group.name) under a set percentage by suspending and resuming it. Stricter than Slow down, and blunter: a suspended app can't respond until it's resumed.")
    }

    private func requestCap(_ pct: Double) {
        if monitor.capAcknowledged { monitor.setCap(group, percent: pct) } else { pendingCap = pct }
    }

    // A browser expands into two halves, because neither half is the whole
    // answer: the tabs have names but no numbers, the renderers have numbers but
    // no names, and macOS won't join them.
    @ViewBuilder private var browserDetail: some View {
        browserTabList
        browserRendererList
    }

    // Real tabs for a scriptable browser: names you recognise, double-click to
    // jump. (macOS won't map a renderer PID to a tab, so we ask the browser.)
    @ViewBuilder private var browserTabList: some View {
        if monitor.tabsNotPermitted.contains(group.name) {
            TabsPermissionRow(appName: group.name)
        } else if let tabs = monitor.browserTabs[group.name] {
            if tabs.isEmpty {
                TabsInfoRow(text: "No open tabs in \(group.name).")
            } else {
                SectionRow(title: "Tabs", count: tabs.count, accent: accent)
                ForEach(tabs) { tab in
                    TabRow(tab: tab, appName: group.name, monitor: monitor, accent: accent)
                }
            }
        } else {
            TabsInfoRow(text: "Reading tabs…")
        }
    }

    // The measurable half. Per-renderer CPU and memory are real; the mapping to
    // a tab is the part that doesn't exist, so the caption says so outright
    // rather than letting the adjacency imply a pairing.
    @ViewBuilder private var browserRendererList: some View {
        let b = BrowserProcs.breakdown(for: group, model: monitor.model)
        if !b.isEmpty {
            SectionRow(title: b.shared ? "Web page processes" : "Renderer processes",
                       count: b.renderers.count, accent: accent,
                       cpu: b.rendererCPU, mem: b.rendererMem)

            ForEach(b.renderers.prefix(Self.rendererLimit), id: \.pid) { p in
                RendererRow(proc: p, monitor: monitor, accent: accent)
            }
            if b.renderers.count > Self.rendererLimit {
                let rest = b.renderers.dropFirst(Self.rendererLimit)
                RollupRow(text: "+\(rest.count) quieter renderers",
                          cpu: rest.reduce(0) { $0 + $1.cpuPct },
                          mem: rest.reduce(0) { $0 + $1.rss })
            }
            if b.supportCount > 0 {
                RollupRow(text: "Support processes (GPU, networking, extensions) ×\(b.supportCount)",
                          cpu: b.supportCPU, mem: b.supportMem)
            }
            TabsInfoRow(text: rendererNote(b), wraps: true)
        }
    }

    private static let rendererLimit = 8

    private func rendererNote(_ b: BrowserProcs.Breakdown) -> String {
        if b.shared {
            return "macOS reparents WebKit page processes away from Safari and shares them "
                 + "with every app that shows web content, so these aren't all Safari's — "
                 + "and none of them can be traced back to a named tab."
        }
        return "\(b.visibleCount) of \(b.renderers.count) renderers serve tabs that are on "
             + "screen; the browser parks the rest in the background band. macOS can't say "
             + "which tab a renderer belongs to, and \(group.name) shares one renderer "
             + "across same-site tabs — so a hot renderer narrows it down, it doesn't name it."
    }
}

/// Header inside an expanded row: names the half you're looking at, and totals
/// it in the same columns as the rows beneath so the numbers line up.
private struct SectionRow: View {
    let title: String
    let count: Int
    var accent: Color
    var cpu: Double? = nil
    var mem: UInt64? = nil

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: UI.chip, weight: .semibold)).foregroundStyle(.secondary)
                    .tracking(0.6)
                Text("\(count)").font(.system(size: UI.chip)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .padding(.leading, 60).frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let cpu {
                    Text(String(format: "%.1f%%", cpu))
                        .font(.system(size: UI.chip)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, alignment: .trailing)
            Group {
                if let mem {
                    Text(fmtBytes(mem))
                        .font(.system(size: UI.chip)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, alignment: .trailing)
            Spacer().frame(width: 282)
        }
        .padding(.horizontal, 22).frame(height: 26)
        .background(Color.primary.opacity(0.04))
    }
}

/// One renderer. No name to give it — the pill and the numbers are everything
/// we actually know.
private struct RendererRow: View {
    var proc: ProcSample
    @ObservedObject var monitor: Monitor
    var accent: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                glyph("squares.leading.rectangle", UI.caption).foregroundStyle(.secondary).frame(width: 16)
                Text("Renderer").font(.system(size: UI.caption)).foregroundStyle(.secondary)
                Text(verbatim: "\(proc.pid)").font(.system(size: UI.chip)).foregroundStyle(.tertiary).monospacedDigit()
                if monitor.isThrottledByUs(proc.pid) {
                    Pill(text: monitor.origin(proc.pid) == .auto ? "auto-slowed" : "slowed",
                         tone: .accent, accent: accent)
                } else if BrowserProcs.isVisible(proc) {
                    Pill(text: "visible tab", tone: .green, accent: accent)
                } else {
                    Pill(text: "background tab", tone: .neutral, accent: accent)
                }
            }
            .padding(.leading, 60).frame(maxWidth: .infinity, alignment: .leading)

            CPUCell(pct: proc.cpuPct, accent: accent, small: true).frame(width: 180, alignment: .trailing)
            Text(fmtBytes(proc.rss)).font(.system(size: UI.caption)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            Spacer().frame(width: 132)
            Group {
                if monitor.isThrottledByUs(proc.pid) {
                    Button("Restore") { monitor.restore(pids: [proc.pid]) }
                        .buttonStyle(.glass).font(.system(size: UI.chip))
                } else if monitor.isProtected(proc) {
                    glyph("lock", UI.chip).foregroundStyle(.tertiary)
                } else {
                    Button("Slow") { monitor.throttle(pids: [proc.pid], origin: .manual, manual: true) }
                        .buttonStyle(.glass).font(.system(size: UI.chip))
                        .opacity(hovering ? 1 : 0.55)
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 22).frame(height: 36)
        .background(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02))
        .onHover { hovering = $0 }
        .help(BrowserProcs.isVisible(proc)
              ? "Serving a tab that's currently on screen. PID \(proc.pid)"
              : "Serving hidden tabs — the browser has parked it in the background band. PID \(proc.pid)")
    }
}

/// The tail of a long list, summed rather than listed.
private struct RollupRow: View {
    let text: String
    let cpu: Double
    let mem: UInt64

    var body: some View {
        HStack(spacing: 0) {
            Text(text).font(.system(size: UI.caption)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.leading, 85).frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", cpu))
                .font(.system(size: UI.caption)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 180, alignment: .trailing)
            Text(fmtBytes(mem))
                .font(.system(size: UI.caption)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)
            Spacer().frame(width: 282)
        }
        .padding(.horizontal, 22).frame(height: 32)
        .background(Color.primary.opacity(0.02))
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let appName: String
    @ObservedObject var monitor: Monitor
    var accent: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            glyph("globe", UI.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(tab.title.isEmpty ? "Untitled" : tab.title)
                .font(.system(size: UI.caption)).lineLimit(1)
            if !tab.host.isEmpty {
                Text(tab.host).font(.system(size: UI.chip)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if tab.active { Pill(text: "frontmost", tone: .accent, accent: accent) }
            Spacer(minLength: 12)
            Button { monitor.jumpToTab(tab, appName: appName) } label: {
                HStack(spacing: 4) { glyph("arrow.up.forward", UI.chip); Text("Jump") }
                    .font(.system(size: UI.chip))
            }
            .buttonStyle(.glass)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Switch to tab \(tab.title)")
        }
        .padding(.leading, 60).padding(.trailing, 22).frame(height: 36)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { monitor.jumpToTab(tab, appName: appName) }
        .help("Double-click to switch to this tab")
    }
}

private struct TabsInfoRow: View {
    let text: String
    /// The renderer caption is a paragraph, not a status line — it has to wrap
    /// rather than truncate, because the caveat is the point of it.
    var wraps = false
    var body: some View {
        Text(text)
            .font(.system(size: wraps ? UI.chip : UI.caption)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 60).padding(.trailing, 120)
            .padding(.vertical, wraps ? 9 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 34)
            .background(Color.primary.opacity(0.02))
    }
}

private struct TabsPermissionRow: View {
    let appName: String
    var body: some View {
        HStack(spacing: 8) {
            glyph("lock.shield", UI.caption).foregroundStyle(.secondary).frame(width: 16)
            Text("Allow ProcessX to control \(appName) to list and jump to its tabs.")
                .font(.system(size: UI.caption)).foregroundStyle(.secondary).lineLimit(1)
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass).font(.system(size: UI.chip))
            Spacer()
        }
        .padding(.leading, 60).padding(.trailing, 22).frame(height: 40)
        .background(Color.primary.opacity(0.02))
    }
}

// "What is this?" popover — a plain-language explanation of a process, its path,
// and a web-lookup fallback for anything the catalog doesn't recognise.
private struct ProcessInfoCard: View {
    let info: ProcInfo
    var count: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                glyph("info.circle", UI.title - 6).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title).font(.system(size: UI.body, weight: .semibold)).lineLimit(1)
                    Text(info.category).font(.system(size: UI.chip)).foregroundStyle(.secondary)
                }
            }
            Text(info.detail).font(.system(size: UI.caption))
                .fixedSize(horizontal: false, vertical: true)
            if !info.path.isEmpty {
                Text(info.path).font(.system(size: UI.chip, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if count > 1 {
                Text("\(count) processes grouped under this app").font(.system(size: UI.chip)).foregroundStyle(.secondary)
            }
            Divider()
            Button {
                if let url = ProcessCatalog.lookupURL(info.title) { NSWorkspace.shared.open(url) }
            } label: {
                Label("Look it up on the web", systemImage: "magnifyingglass").font(.system(size: UI.caption))
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

private struct BigChildRow: View {
    var proc: ProcSample
    @ObservedObject var monitor: Monitor
    var accent: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(Grouping.label(proc)).font(.system(size: UI.caption)).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: "\(proc.pid)").font(.system(size: UI.chip)).foregroundStyle(.tertiary).monospacedDigit()
                if monitor.isThrottledByUs(proc.pid) {
                    Pill(text: monitor.origin(proc.pid) == .auto ? "auto-slowed" : "slowed", tone: .accent, accent: accent)
                } else if proc.priority <= Sampler.bgBand {
                    Pill(text: "bg (self)", tone: .neutral, accent: accent)
                }
            }
            .padding(.leading, 60).frame(maxWidth: .infinity, alignment: .leading)

            CPUCell(pct: proc.cpuPct, accent: accent, small: true).frame(width: 180, alignment: .trailing)
            Text(fmtBytes(proc.rss)).font(.system(size: UI.caption)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Spacer().frame(width: 132)
            Group {
                if monitor.isThrottledByUs(proc.pid) {
                    Button("Restore") { monitor.restore(pids: [proc.pid]) }
                        .buttonStyle(.glass).font(.system(size: UI.chip))
                } else if monitor.isProtected(proc) {
                    glyph("lock", UI.chip).foregroundStyle(.tertiary)
                } else {
                    Button("Slow") { monitor.throttle(pids: [proc.pid], origin: .manual, manual: true) }
                        .buttonStyle(.glass).font(.system(size: UI.chip))
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 22).frame(height: 36)
        .background(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02))
        .onHover { hovering = $0 }
        .help(childTooltip)
    }

    private var childTooltip: String {
        let i = ProcessCatalog.describe(label: Grouping.label(proc), path: proc.path)
        return "\(i.title)\n\(i.detail)\nPID \(proc.pid)"
    }
}

private struct CPUCell: View {
    var pct: Double
    var accent: Color
    var small = false
    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(String(format: "%.1f%%", pct))
                .font(.system(size: small ? UI.caption : UI.num)).monospacedDigit()
            Capsule().fill(.quaternary).frame(width: 78, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(pct > 85 ? Color.red : pct > 50 ? Color.orange : accent)
                        .frame(width: max(pct > 0.5 ? 3 : 0, min(1, pct / 100) * 78), height: 5)
                }
        }
    }
}

private enum Tone { case accent, green, neutral, warn }

private struct Pill: View {
    var text: String
    var tone: Tone = .neutral
    var accent: Color
    var body: some View {
        Text(text)
            .font(.system(size: UI.chip, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
    private var fg: Color {
        switch tone {
        case .accent: return accent
        case .green: return .green
        case .neutral: return .secondary
        // A cap suspends the app — it should not look like the same routine,
        // fully-reversible state that "slowed" does.
        case .warn: return .orange
        }
    }
    private var bg: some ShapeStyle {
        switch tone {
        case .accent: return AnyShapeStyle(accent.opacity(0.16))
        case .green: return AnyShapeStyle(Color.green.opacity(0.16))
        case .neutral: return AnyShapeStyle(.quaternary)
        case .warn: return AnyShapeStyle(Color.orange.opacity(0.18))
        }
    }
}
