import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

struct AppliedChange: Equatable {
    var pids: [pid_t]
    var names: [String]
}

@MainActor
final class Monitor: ObservableObject {
    /// Deliberately **not** `@Published`, along with `throttled`, `caps` and the
    /// two histories below.
    ///
    /// `Monitor` is a plain `ObservableObject`, so any `@Published` assignment
    /// invalidates the window — there is no way to publish to the menu bar
    /// without also redrawing a window nobody may be looking at. These five are
    /// read by the app's own logic (auto-tame, cap reconciliation, the identity
    /// guard on restore), so they must stay fresh every tick regardless. Keeping
    /// them unpublished is what lets `tick` go quiet while the window is hidden;
    /// the properties that only the window reads are assigned below the
    /// `uiActive` gate, and re-reading these is part of that redraw.
    ///
    /// **Rule for view code:** a view may read these, but must never be the only
    /// reason a redraw is needed. Nothing here triggers one. Today the browser
    /// row's renderer list reads `model` via `BrowserProcs.breakdown`, and it
    /// stays correct only because a visible tick publishes something *else* in
    /// the same pass. A view whose content depended on one of these five alone
    /// would freeze while looking perfectly normal — no crash, no blank space,
    /// just a number that quietly stopped being true. If you need a view to
    /// react to one of these, publish a derived value next to `visibleGroups`
    /// rather than reaching in here.
    private(set) var model = Model()
    @Published private(set) var totalCPU: Double = 0      // % of the whole machine
    @Published private(set) var gpu: Int?
    @Published private(set) var memory = MemoryStats()
    private(set) var throttled: [ThrottleRecord] = []
    /// Groups currently held under a hard CPU cap (suspend/resume duty cycle).
    private(set) var caps: [CapRecord] = []
    @Published var search: String = "" { didSet { refreshVisible() } }
    @Published var showSystem = false { didSet { refreshVisible() } }
    @Published var lastMessage: String?
    @Published private(set) var lastApplied: AppliedChange?
    /// Rolling history for the sparklines (newest last). Kept filling while the
    /// window is hidden — otherwise the sparkline would show a gap for exactly
    /// the period the user was not watching, which is the part worth seeing when
    /// they come back.
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    @Published var sort: SortKey = .cpu { didSet { refreshVisible() } }
    /// Sort direction for the active column. Activity-Monitor style: click a
    /// column header to sort by it; click again to flip direction.
    @Published var sortAscending = false { didSet { refreshVisible() } }

    /// Row positions are held still while the pointer is over the table.
    ///
    /// Sorting by CPU re-ranks every two seconds, so a row moves out from under
    /// the cursor between aiming and clicking — and the click lands on whatever
    /// took its place. For a button labelled "Slow down" that is not a cosmetic
    /// problem: you throttle an app you never chose. Only the *order* is frozen;
    /// CPU, memory and every pill keep updating live.
    @Published private(set) var orderFrozen = false
    /// Sticky hold, so the order survives the pointer leaving the table.
    @Published private(set) var orderPinned = false
    private var hoveringTable = false
    private var frozenKeys: [String] = []

    func hoverTable(_ inside: Bool) {
        hoveringTable = inside
        updateFreeze()
    }

    func togglePin() {
        orderPinned.toggle()
        updateFreeze()
    }

    /// Snapshot the order *before* flipping the flag, so the frozen ranking is
    /// the one the user is currently looking at.
    private func updateFreeze() {
        let want = hoveringTable || orderPinned
        guard want != orderFrozen else { return }
        if want { frozenKeys = visibleGroups.map(\.key) }
        orderFrozen = want
        refreshVisible()
    }

    // Real browser tabs (title + jump), keyed by browser app name. The OS can't
    // map a renderer PID to a tab, so an expanded browser row asks the browser
    // itself via Apple Events. nil = not yet read; [] = read, none open.
    @Published private(set) var browserTabs: [String: [BrowserTab]] = [:]
    @Published private(set) var tabsNotPermitted: Set<String> = []

    enum SortKey: String, CaseIterable, Identifiable {
        case name, cpu, memory, priority
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .name: return "Name"
            case .priority: return "Priority"
            }
        }
        /// The natural first-click direction: names read A→Z, everything else
        /// high→low (busiest / most-throttled first).
        var defaultAscending: Bool { self == .name }
    }

    /// Click a column header: the same column flips direction; a new column
    /// adopts that column's natural default direction.
    func setSort(_ key: SortKey) {
        if sort == key { sortAscending.toggle() }
        else { sort = key; sortAscending = key.defaultAscending }
    }

    /// Auto-tame: throttle a background process only after it has been hot for
    /// `autoStreak` consecutive samples, so brief spikes are never punished.
    @AppStorage("autoTame") var autoTame = false
    @AppStorage("cpuThreshold") var cpuThreshold: Double = 25
    /// Slow-hog alerts: when a background app group stays hot, ask instead of
    /// silently acting — a system notification offering Cap or Slow down. On by
    /// default, unlike Auto-tame, because asking first is the safer default and
    /// a group Auto-tame already grabbed never reaches this (see `alreadyHandled`
    /// in `slowProcessCandidates`).
    @AppStorage("notifySlowProcesses") var notifySlowProcesses = true
    @AppStorage("theme") var themeName: String = AppTheme.liquidGlass.rawValue
    /// Whether the "a cap suspends the app" explainer has been shown and accepted.
    @AppStorage("capAcknowledged") var capAcknowledged = false
    var theme: AppTheme { AppTheme(rawValue: themeName) ?? .liquidGlass }

    private let sampler = Sampler()
    private let store = ThrottleStore()
    private let capper = Capper()
    private let myUID = getuid()
    private let selfPID = getpid()
    private var timer: Timer?

    private let autoStreak = 3
    private let restoreCooldown: TimeInterval = 600
    private var hotStreak: [pid_t: Int] = [:]
    private var cooldownUntil: [pid_t: Date] = [:]
    /// Coalesce back-to-back action samples (throttle then UI refresh) into one tick.
    private var tickCoalescePending = false

    private let alertStreak = 3
    private let alertCooldown: TimeInterval = 600
    private var alertHotStreak: [String: Int] = [:]
    private var alertCooldownUntil: [String: Date] = [:]
    private var alerter: SlowProcessAlerter?

    /// Whether the OS notification bridge must stay off: either a CLI path that
    /// already does its own headless thing (selftest, bench, render, the cap
    /// guardian — these must never trigger a real permission prompt or an actual
    /// banner, or `--selftest` would fire one on every run), or `.build/debug/
    /// ProcessX` run straight off the command line rather than as `ProcessX.app`.
    /// `UNUserNotificationCenter.current()` requires a real bundle identifier —
    /// there is none outside a proper `.app`, and calling it anyway throws. Only
    /// the bundled app stands up the bridge.
    private static var skipsNotificationBridge: Bool {
        let flags: Set<String> = ["--selftest", "--bench", "--bench-view", "--bench-live",
                                   "--render", "--cap-guardian"]
        if !flags.isDisjoint(with: Set(CommandLine.arguments)) { return true }
        return Bundle.main.bundleIdentifier == nil
    }

    init() {
        // Before anything else can be suspended: let go of anything a previous run
        // died holding, and arm the handlers that resume on the way out.
        Capper.releaseOrphans()
        CapEmergency.install()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.capper.clearAllSync()
        }

        if !Self.skipsNotificationBridge {
            alerter = SlowProcessAlerter(monitor: self)
        }

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var menuBarTitle: String { menuBar.text }

    // MARK: - is anyone looking?

    /// The menu-bar percentage, in its own tiny observable.
    ///
    /// It has to keep ticking while the window is hidden, and it cannot live on
    /// `Monitor` to do that: publishing it there would invalidate the window too,
    /// which is the entire cost being avoided. So the menu bar observes this and
    /// nothing else.
    @MainActor
    final class MenuBarTitle: ObservableObject {
        @Published fileprivate(set) var text = "–"
    }

    let menuBar = MenuBarTitle()

    /// Whether anything is on screen that needs the numbers refreshed.
    ///
    /// A hidden window is not a rare state — it is the normal one for a monitor
    /// you glance at. Sampling, auto-tame and cap reconciliation carry on
    /// regardless; only the publishing stops.
    private(set) var windowVisible = true
    private(set) var menuOpen = false
    var uiActive: Bool { windowVisible || menuOpen }

    /// Last tick's readings, so becoming visible can publish immediately without
    /// taking a fresh sample. Re-sampling here would measure a millisecond-long
    /// interval and report nonsense percentages for it.
    private var lastCPU: Double = 0
    private var lastGPU: Int?

    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        uiActiveChanged()
    }

    func setMenuOpen(_ open: Bool) {
        guard open != menuOpen else { return }
        menuOpen = open
        uiActiveChanged()
    }

    private func uiActiveChanged() {
        guard uiActive else { return }
        publishForUI()
    }

    /// Everything the window reads and the rest of the app does not.
    private func publishForUI() {
        totalCPU = lastCPU
        gpu = lastGPU
        memory = SystemStats.memory()
        refreshVisible()
    }

    // MARK: - sampling

    func tick() {
        let procs = sampler.sample()
        guard !procs.isEmpty else { return }   // a bad read must never look like "everything exited"

        var m = Grouping.build(procs: procs, frontPID: SystemStats.frontmostPID(), myUID: myUID)
        m.groups.sort { $0.cpu > $1.cpu }

        store.reconcile(live: m.byPID)

        // Annotate a local copy and assign once. Writing through `m.groups[i]`
        // would run the array's `didSet` — and so rebuild the key index — for
        // every group in turn, which is quadratic in the number of groups.
        var annotated = m.groups
        for i in annotated.indices {
            annotated[i].throttledByUs = annotated[i].procs.reduce(0) {
                $0 + (store.record($1.pid) == nil ? 0 : 1)
            }
        }
        m.groups = annotated

        model = m
        throttled = store.all.sorted { $0.at > $1.at }
        reconcileCaps()

        lastCPU = min(100, procs.reduce(0) { $0 + $1.cpuPct } / Double(SystemStats.coreCount))
        lastGPU = SystemStats.gpuUtilization()

        if sampler.hasBaseline {
            cpuHistory.append(lastCPU)
            gpuHistory.append(Double(lastGPU ?? 0))
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
            if gpuHistory.count > 60 { gpuHistory.removeFirst() }
        }

        // The glance always stays live, hidden window or not.
        menuBar.text = sampler.hasBaseline ? "\(Int(lastCPU.rounded()))%" : "–"

        if autoTame { autoTameTick() }
        // Runs after autoTameTick: a group Auto-tame just grabbed already shows
        // `throttledByUs > 0` by this point, so it can never also trigger an
        // alert on the same tick — no separate mutual-exclusion check needed.
        if notifySlowProcesses { slowProcessWatchTick() }

        // Below this line everything notifies SwiftUI, and a notification means a
        // full window rebuild — ~90% of what this app costs. With nothing on
        // screen to notify, it buys nothing. Note the order: autoTameTick can
        // change what's throttled, which both the filter and the priority sort read.
        guard uiActive else { return }
        publishForUI()
    }

    // MARK: - actions

    /// `manual` relaxes the media guard: an explicit click is not a surprise.
    @discardableResult
    func throttle(pids: [pid_t], origin: ThrottleOrigin, manual: Bool) -> AppliedChange {
        Audit.log("REQUEST  origin=\(origin.rawValue) manual=\(manual) count=\(pids.count)")
        var applied: [pid_t] = []
        var names: [String] = []
        var refusals: [String] = []

        for pid in pids {
            guard let p = model.byPID[pid] else { continue }
            if store.record(pid) != nil { continue }
            if let why = Policy.ineligibleReason(p, manual: manual, myUID: myUID, selfPID: selfPID) {
                refusals.append("\(p.name): \(why)")
                continue
            }
            guard Throttle.setBackground(pid, true) else {
                refusals.append("\(p.name): kernel refused")
                continue
            }
            let display = Grouping.appName(of: p.path) ?? p.name
            store.add(ThrottleRecord(pid: pid, path: p.path, name: display, origin: origin, at: Date()))
            applied.append(pid)
            names.append(display)
        }
        if applied.isEmpty, let first = refusals.first { lastMessage = "Couldn't slow \(first)" }
        scheduleTick()
        let change = AppliedChange(pids: applied, names: Array(Set(names)).sorted())
        if !applied.isEmpty { lastApplied = change }
        return change
    }

    func restore(pids: [pid_t]) {
        Audit.log("REQUEST  restore count=\(pids.count)")
        var n = 0
        for pid in pids {
            guard let rec = store.record(pid) else { continue }
            // Identity guard: never lift a throttle off a recycled pid.
            if let p = model.byPID[pid], p.path == rec.path {
                _ = Throttle.setBackground(pid, false)
                n += 1
            }
            store.remove(pid)
            hotStreak[pid] = nil
            cooldownUntil[pid] = Date().addingTimeInterval(restoreCooldown)
        }
        if n > 0 { lastMessage = "Restored \(n) process\(n == 1 ? "" : "es") to normal priority" }
        lastApplied = nil
        scheduleTick()
    }

    /// Debounce action-driven resampling so throttle+message paths don't sample twice.
    private func scheduleTick() {
        guard !tickCoalescePending else { return }
        tickCoalescePending = true
        DispatchQueue.main.async { [weak self] in
            self?.tickCoalescePending = false
            self?.tick()
        }
    }

    func restoreAll() { restore(pids: store.all.map(\.pid)) }

    func throttleGroup(_ g: ProcGroup) {
        let change = throttle(pids: g.procs.map(\.pid), origin: .manual, manual: true)
        if !change.pids.isEmpty {
            lastMessage = "\(g.name) moved to background priority (\(change.pids.count) process\(change.pids.count == 1 ? "" : "es"))"
        }
    }

    func restoreGroup(_ g: ProcGroup) {
        restore(pids: g.procs.map(\.pid).filter { store.record($0) != nil })
    }

    // MARK: - hard caps

    /// The percentages offered in the UI, in % of one core — the same unit as the
    /// CPU column, so "cap at 25%" and "25.0%" in the table mean the same thing.
    static let capChoices: [Double] = [5, 10, 25, 50]

    func cap(forKey key: String) -> CapRecord? { caps.first { $0.key == key } }
    func isCapped(_ key: String) -> Bool { cap(forKey: key) != nil }

    /// Why this group can't be capped, or nil if it can. Drives both the menu's
    /// disabled state and the refusal message, so they can't disagree.
    func capRefusal(_ g: ProcGroup) -> String? {
        if model.isFront(g.key) { return "it's the app you're using" }
        if g.isCritical || !g.actionable { return "it's a protected system process" }
        if capTargets(g).isEmpty {
            let first = g.procs.compactMap {
                Policy.capIneligibleReason($0, myUID: myUID, selfPID: selfPID)
            }.first
            return first ?? "nothing in it can be suspended"
        }
        return nil
    }

    /// `ours` = pids this cap already holds, which are legitimately suspended right
    /// now because we suspended them.
    private func capTargets(_ g: ProcGroup, ours: Set<pid_t> = []) -> [CapTarget] {
        g.procs
            .filter {
                Policy.capIneligibleReason($0, myUID: myUID, selfPID: selfPID,
                                           alreadyCapped: ours.contains($0.pid)) == nil
            }
            .map { CapTarget(pid: $0.pid, path: $0.path) }
    }

    func setCap(_ g: ProcGroup, percent: Double) {
        if let why = capRefusal(g) {
            lastMessage = "Can't cap \(g.name) — \(why)"
            return
        }
        let targets = capTargets(g)
        capper.set(key: g.key, name: g.name, percent: percent, targets: targets)
        caps = capper.snapshot()
        lastMessage = "\(g.name) capped at \(Int(percent))% of a core "
            + "(\(targets.count) process\(targets.count == 1 ? "" : "es"), suspended and resumed in turn)"
    }

    func clearCap(_ g: ProcGroup) { clearCap(key: g.key, name: g.name) }

    func clearCap(key: String, name: String) {
        capper.clear(key)
        caps = capper.snapshot()
        lastMessage = "Cap removed from \(name) — running at full speed again"
    }

    func clearAllCaps() {
        capper.clearAll()
        caps = capper.snapshot()
        lastMessage = "All caps removed"
    }

    /// Per-tick cap maintenance: re-resolve each capped group's pids (helpers come
    /// and go), and release a cap the moment its app comes to the front — the same
    /// focus rescue auto-tame does, and far more important here, because a
    /// suspended app you just clicked on is a beachball.
    private func reconcileCaps() {
        guard !caps.isEmpty else { return }

        for record in caps where model.isFront(record.key) {
            capper.clear(record.key)
            lastMessage = "\(record.name) came to the front — cap released"
        }

        var fresh: [String: [CapTarget]] = [:]
        for record in caps where !model.isFront(record.key) {
            guard let g = model.group(for: record.key) else { continue }
            fresh[record.key] = capTargets(g, ours: Set(record.targets.map(\.pid)))
        }
        capper.refresh(fresh)
        caps = capper.snapshot()
    }

    // MARK: - quit

    /// The pids between us and launchd. Quitting one of them takes ProcessX down
    /// with it — most visibly when the app is run from a terminal, where the
    /// terminal and its shell are ordinary rows in the table like any other.
    private var selfAncestors: Set<pid_t> {
        var out: Set<pid_t> = []
        var cur = selfPID
        var hops = 0
        while hops < 40, let p = model.byPID[cur], p.ppid > 1 {
            out.insert(p.ppid)
            cur = p.ppid
            hops += 1
        }
        return out
    }

    /// The processes in this group that may be ended, in the order they'd be asked.
    private func quitTargets(_ g: ProcGroup) -> [ProcSample] {
        let ancestors = selfAncestors
        return g.procs.filter {
            Policy.quitIneligibleReason($0, myUID: myUID, selfPID: selfPID, ancestors: ancestors) == nil
        }
    }

    /// Why this group can't be quit, or nil if it can. Drives the menu's disabled
    /// state and the refusal message both, so the two can't disagree.
    func quitRefusal(_ g: ProcGroup) -> String? {
        if g.isCritical { return "it's a protected system process" }
        guard quitTargets(g).isEmpty else { return nil }
        let ancestors = selfAncestors
        return g.procs.compactMap {
            Policy.quitIneligibleReason($0, myUID: myUID, selfPID: selfPID, ancestors: ancestors)
        }.first ?? "nothing in it can be quit"
    }

    /// True when this one process can be ended — the per-process rows use it to
    /// choose between a Quit menu and a padlock.
    func isQuittable(_ p: ProcSample) -> Bool {
        Policy.quitIneligibleReason(p, myUID: myUID, selfPID: selfPID, ancestors: selfAncestors) == nil
    }

    func quitGroup(_ g: ProcGroup, mode: Quit.Mode) {
        if let why = quitRefusal(g) {
            lastMessage = "Can't quit \(g.name) — \(why)"
            return
        }
        // A capped app spends most of every period suspended. Asking it to quit
        // in that state is asking a process that isn't running, so the cap goes
        // first — and a cap on a process that is about to die is dead weight
        // anyway, holding pids the capper would keep signalling.
        if isCapped(g.key) {
            capper.clear(g.key)
            caps = capper.snapshot()
        }

        let targets = quitTargets(g)
        // Asking goes to the roots of the tree — the app process, not its 90
        // helpers, because an app shuts its own helpers down and asking each of
        // them separately produces 90 quit requests and one confused browser.
        // Force quit takes every pid: a killed parent has no chance to take its
        // children with it, and orphaned helpers keep burning the CPU that
        // prompted the click.
        let inGroup = Set(g.procs.map(\.pid))
        let roots = targets.filter { !inGroup.contains($0.ppid) }
        let chosen = mode == .ask ? (roots.isEmpty ? targets : roots) : targets

        Audit.log("REQUEST  quit mode=\(mode.rawValue) group=\(g.key) targets=\(chosen.count)")
        send(mode, to: chosen, label: g.name)
    }

    /// Quit one process out of an expanded row.
    func quit(pid: pid_t, mode: Quit.Mode) {
        guard let p = model.byPID[pid] else {
            lastMessage = "That process has already exited"
            return
        }
        if let why = Policy.quitIneligibleReason(p, myUID: myUID, selfPID: selfPID, ancestors: selfAncestors) {
            lastMessage = "Can't quit \(Grouping.label(p)) — \(why)"
            return
        }
        Audit.log("REQUEST  quit mode=\(mode.rawValue) pid=\(pid)")
        send(mode, to: [p], label: Grouping.label(p))
    }

    private func send(_ mode: Quit.Mode, to targets: [ProcSample], label: String) {
        var sent = 0
        var refusals: [String] = []
        for p in targets {
            if let why = Quit.send(pid: p.pid, path: p.path, mode: mode) { refusals.append(why) }
            else { sent += 1 }
        }

        guard sent > 0 else {
            lastMessage = "Couldn't quit \(label) — \(refusals.first ?? "nothing left to quit")"
            scheduleTick()
            return
        }
        lastMessage = mode == .ask
            ? "Asked \(label) to quit — it may ask you to save first"
            : "Force quit \(label) (\(sent) process\(sent == 1 ? "" : "es"))"
        // Anything we were tracking about a process that is on its way out stops
        // being true; the next reconcile drops it, this just doesn't wait for it.
        for p in targets { hotStreak[p.pid] = nil }
        scheduleTick()
        verifyQuit(targets.map { ($0.pid, $0.path) }, label: label, mode: mode)
    }

    /// A request is not an outcome. An app asked to quit may put up a "Save
    /// changes?" sheet and sit there, or refuse outright — both look identical to
    /// a button that did nothing, so check back and say which it was.
    private func verifyQuit(_ targets: [(pid_t, String)], label: String, mode: Quit.Mode) {
        guard mode == .ask else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            let alive = targets.filter { !Quit.hasExited(pid: $0.0, path: $0.1) }
            guard !alive.isEmpty else { return }
            self.lastMessage = "\(label) is still running — it may be waiting on you, "
                + "or refusing. Force Quit ends it outright."
        }
    }

    // MARK: - QuickFast

    func quickFast() {
        let targets = quickFastTargets()
        guard !targets.isEmpty else {
            lastMessage = "QuickFast: nothing to slow down — no background hogs found"
            lastApplied = nil
            return
        }
        let change = throttle(pids: targets, origin: .quickFast, manual: false)
        if change.pids.isEmpty {
            lastMessage = "QuickFast: nothing eligible to slow down"
        } else {
            let shown = change.names.prefix(4).joined(separator: ", ")
            let extra = change.names.count > 4 ? " +\(change.names.count - 4) more" : ""
            lastMessage = "QuickFast: slowed \(change.pids.count) process\(change.pids.count == 1 ? "" : "es") — \(shown)\(extra)"
        }
    }

    func quickFastTargets() -> [pid_t] {
        model.byPID.values.filter { p in
            guard store.record(p.pid) == nil else { return false }
            guard !model.isFront(p.groupKey) else { return false }   // never the app you're using
            guard Policy.ineligibleReason(p, manual: false, myUID: myUID, selfPID: selfPID) == nil else { return false }
            let groupName = model.group(for: p.groupKey)?.name ?? ""
            let hay = p.path + " " + groupName
            let nameHit = Policy.quickFastNames.contains { Policy.matches($0, hay) }
            let cpuHit = p.cpuPct >= cpuThreshold
            // Name matches only count when actually working — don't throttle idle agents.
            if nameHit && p.cpuPct < 1 && !cpuHit { return false }
            return nameHit || cpuHit
        }
        .sorted { $0.cpuPct > $1.cpuPct }
        .map(\.pid)
    }

    // MARK: - auto-tame

    private func autoTameTick() {
        // Focus rescue: you switched to something we tamed -> give it back.
        for rec in store.all where rec.origin == .auto {
            if let p = model.byPID[rec.pid], p.path == rec.path, model.isFront(p.groupKey) {
                _ = Throttle.setBackground(rec.pid, false)
                store.remove(rec.pid)
                hotStreak[rec.pid] = nil
            }
        }

        let now = Date()
        var toTame: [pid_t] = []
        var seen = Set<pid_t>()

        for p in model.byPID.values {
            seen.insert(p.pid)
            let cooling = (cooldownUntil[p.pid].map { now < $0 }) ?? false
            let hot = p.cpuPct >= cpuThreshold
                && !model.isFront(p.groupKey)
                && store.record(p.pid) == nil
                && !cooling
                && Policy.ineligibleReason(p, manual: false, myUID: myUID, selfPID: selfPID) == nil
            guard hot else { hotStreak[p.pid] = nil; continue }
            let streak = (hotStreak[p.pid] ?? 0) + 1
            hotStreak[p.pid] = streak
            if streak >= autoStreak { toTame.append(p.pid) }
        }

        hotStreak = hotStreak.filter { seen.contains($0.key) }
        cooldownUntil = cooldownUntil.filter { $0.value > now }

        guard !toTame.isEmpty else { return }
        var applied: [String] = []
        for pid in toTame {
            guard let p = model.byPID[pid] else { continue }
            guard Throttle.setBackground(pid, true) else { continue }
            let display = Grouping.appName(of: p.path) ?? p.name
            store.add(ThrottleRecord(pid: pid, path: p.path, name: display, origin: .auto, at: Date()))
            hotStreak[pid] = nil
            applied.append(display)
        }
        if !applied.isEmpty {
            // Already inside tick() — refresh published list only, don't re-sample.
            throttled = store.all.sorted { $0.at > $1.at }
            lastMessage = "Auto-tamed \(Array(Set(applied)).sorted().joined(separator: ", "))"
        }
    }

    // MARK: - slow-process alerts

    /// App groups worth interrupting the user about: hot for `alertStreak`
    /// consecutive samples, not the app in front, not system/critical, not
    /// already handled (by us or by Auto-tame), and not still cooling down from
    /// a previous alert. Grouped rather than per-process, because both actions
    /// on offer — Cap and Slow down — already act on the whole group.
    ///
    /// Pure and side-effect-free so it can be exercised directly from tests
    /// without touching `UNUserNotificationCenter`.
    func slowProcessCandidates() -> [ProcGroup] {
        let now = Date()
        var seen = Set<String>()
        var candidates: [ProcGroup] = []

        for g in model.groups {
            seen.insert(g.key)
            let cooling = (alertCooldownUntil[g.key].map { now < $0 }) ?? false
            let alreadyHandled = g.throttledByUs > 0 || isCapped(g.key)
            let hot = g.cpu >= cpuThreshold
                && g.actionable
                && !model.isFront(g.key)
                && !alreadyHandled
                && !cooling
            guard hot else { alertHotStreak[g.key] = nil; continue }
            let streak = (alertHotStreak[g.key] ?? 0) + 1
            alertHotStreak[g.key] = streak
            if streak >= alertStreak { candidates.append(g) }
        }

        alertHotStreak = alertHotStreak.filter { seen.contains($0.key) }
        alertCooldownUntil = alertCooldownUntil.filter { $0.value > now }
        return candidates
    }

    private func slowProcessWatchTick() {
        for g in slowProcessCandidates() {
            // Cooldown starts the moment the alert goes out, whether or not the
            // user ever answers it — otherwise an ignored notification would fire
            // again on the very next tick.
            alertCooldownUntil[g.key] = Date().addingTimeInterval(alertCooldown)
            Audit.log("ALERT    key=\(g.key) name=\(g.name) cpu=\(String(format: "%.1f", g.cpu))")
            alerter?.alert(key: g.key, name: g.name, cpuPercent: g.cpu, offerCap: capRefusal(g) == nil)
        }
    }

    /// The percentage a "Cap" notification action applies — the same default the
    /// speedometer menu leads with.
    static let alertCapPercent: Double = 25

    /// Reached from the notification's "Slow Down" button, which can fire with no
    /// window or popover open. The group may have changed shape or vanished by
    /// the time the user answers, so it's re-resolved by key rather than trusting
    /// what the alert was built from.
    func slowDownFromAlert(key: String) {
        guard let g = model.group(for: key) else { return }
        throttleGroup(g)
    }

    /// Reached from the notification's "Cap" button. The notification body
    /// already spelled out how a cap differs from Slow down before the user
    /// picked it, so this counts as the one-time explainer having been shown.
    func capFromAlert(key: String) {
        guard let g = model.group(for: key) else { return }
        guard capRefusal(g) == nil else {
            lastMessage = "Couldn't cap \(g.name) — it changed before you answered"
            return
        }
        capAcknowledged = true
        setCap(g, percent: Self.alertCapPercent)
    }

    // MARK: - view helpers

    /// The table's rows, recomputed once per tick rather than once per read.
    ///
    /// This used to be a computed property, and `MainWindow` reads it three times
    /// in a single body pass — the "N apps" count, the empty check, and the rows
    /// themselves. A filter plus a sort over every group on the machine therefore
    /// ran three times per redraw to produce one answer, and more than that
    /// whenever anything in the window was animating. It is now recomputed
    /// exactly when its inputs change.
    @Published private(set) var visibleGroups: [ProcGroup] = []

    /// Everything `visibleGroups` depends on that isn't the model itself.
    private func refreshVisible() { visibleGroups = computeVisibleGroups() }

    private func computeVisibleGroups() -> [ProcGroup] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = model.groups.filter { g in
            // Don't list ourselves — we can't act on it, so it's just noise.
            if g.procs.contains(where: { $0.pid == selfPID }) { return false }
            if !showSystem && g.isSystem && q.isEmpty { return false }
            if !q.isEmpty {
                return g.name.lowercased().contains(q)
                    || g.procs.contains { Grouping.label($0).lowercased().contains(q) }
            }
            return g.cpu > 0.05 || g.mem > 20 * 1024 * 1024
                || g.procs.contains { store.record($0.pid) != nil }
        }
        // Build one ascending comparator per column, then reverse for descending
        // so every column toggles direction consistently.
        let asc: (ProcGroup, ProcGroup) -> Bool
        switch sort {
        case .cpu: asc = { $0.cpu < $1.cpu || ($0.cpu == $1.cpu && $0.mem < $1.mem) }
        case .memory: asc = { $0.mem < $1.mem || ($0.mem == $1.mem && $0.cpu < $1.cpu) }
        case .name: asc = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .priority: asc = {
            let (a, b) = (self.throttleRank($0), self.throttleRank($1))
            return a < b || (a == b && $0.cpu < $1.cpu)
        }
        }
        let ranked = filtered.sorted(by: asc)
        let live = sortAscending ? ranked : Array(ranked.reversed())

        guard orderFrozen, !frozenKeys.isEmpty else { return live }

        // Hold every row the user could already see in the position they saw it.
        // A group that appeared *after* the freeze goes to the end rather than
        // pushing the row being aimed at further down — the whole point is that
        // nothing moves under the cursor. Rows whose process exited simply drop
        // out; nothing can be done about that, and it doesn't displace anything
        // above them.
        var rank: [String: Int] = [:]
        rank.reserveCapacity(frozenKeys.count)
        for (i, key) in frozenKeys.enumerated() { rank[key] = i }

        return live.enumerated().sorted { l, r in
            switch (rank[l.element.key], rank[r.element.key]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return l.offset < r.offset   // newcomers keep live order
            }
        }.map(\.element)
    }

    /// Priority-column rank: 0 = normal, 1 = some of the group throttled by us,
    /// 2 = the whole group in the background band.
    private func throttleRank(_ g: ProcGroup) -> Int {
        let t = g.throttledByUs
        return t == 0 ? 0 : (t == g.count ? 2 : 1)
    }

    func isThrottledByUs(_ pid: pid_t) -> Bool { store.record(pid) != nil }
    func origin(_ pid: pid_t) -> ThrottleOrigin? { store.record(pid)?.origin }

    // MARK: - browser tabs

    /// A group whose expansion should show real tabs instead of renderer PIDs.
    func isBrowser(_ g: ProcGroup) -> Bool { g.kind == .app && BrowserTabs.engine(for: g.name) != nil }

    /// Read the browser's open tabs off the main thread, then publish on main.
    /// Called when a browser row is expanded, and to refresh.
    func refreshTabs(_ appName: String) {
        Task {
            let result = await Task.detached { BrowserTabs.list(appName: appName) }.value
            switch result {
            case .success(let tabs):
                browserTabs[appName] = tabs
                tabsNotPermitted.remove(appName)
            case .failure(let e):
                if e.message == "not-permitted" { tabsNotPermitted.insert(appName) }
                else { lastMessage = "Couldn't read \(appName) tabs: \(e.message)" }
            }
        }
    }

    /// Bring the browser forward with this tab selected.
    func jumpToTab(_ tab: BrowserTab, appName: String) {
        Task {
            let err = await Task.detached { BrowserTabs.focus(appName: appName, tab: tab) }.value
            if let err {
                if err.message == "not-permitted" { tabsNotPermitted.insert(appName) }
                else { lastMessage = "Couldn't switch tab: \(err.message)" }
            }
        }
    }

    /// True when even an explicit click can't touch it (protected, another user's,
    /// or ProcessX itself). Drives the padlock in the UI.
    func isProtected(_ p: ProcSample) -> Bool {
        Policy.ineligibleReason(p, manual: true, myUID: myUID, selfPID: selfPID) != nil
    }
}
