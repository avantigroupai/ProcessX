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
    @Published private(set) var model = Model()
    @Published private(set) var totalCPU: Double = 0      // % of the whole machine
    @Published private(set) var gpu: Int?
    @Published private(set) var memory = MemoryStats()
    @Published private(set) var throttled: [ThrottleRecord] = []
    /// Groups currently held under a hard CPU cap (suspend/resume duty cycle).
    @Published private(set) var caps: [CapRecord] = []
    @Published var search: String = ""
    @Published var showSystem = false
    @Published var lastMessage: String?
    @Published private(set) var lastApplied: AppliedChange?
    /// Rolling history for the sparklines (newest last).
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published var sort: SortKey = .cpu
    /// Sort direction for the active column. Activity-Monitor style: click a
    /// column header to sort by it; click again to flip direction.
    @Published var sortAscending = false

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

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var menuBarTitle: String {
        sampler.hasBaseline ? "\(Int(totalCPU.rounded()))%" : "–"
    }

    // MARK: - sampling

    func tick() {
        let procs = sampler.sample()
        guard !procs.isEmpty else { return }   // a bad read must never look like "everything exited"

        var m = Grouping.build(procs: procs, frontPID: SystemStats.frontmostPID(), myUID: myUID)
        m.groups.sort { $0.cpu > $1.cpu }

        store.reconcile(live: m.byPID)
        model = m
        throttled = store.all.sorted { $0.at > $1.at }
        reconcileCaps()
        totalCPU = min(100, procs.reduce(0) { $0 + $1.cpuPct } / Double(SystemStats.coreCount))
        gpu = SystemStats.gpuUtilization()
        memory = SystemStats.memory()

        if sampler.hasBaseline {
            cpuHistory.append(totalCPU)
            gpuHistory.append(Double(gpu ?? 0))
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
            if gpuHistory.count > 60 { gpuHistory.removeFirst() }
        }

        if autoTame { autoTameTick() }
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

    // MARK: - view helpers

    var visibleGroups: [ProcGroup] {
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
        let sorted = filtered.sorted(by: asc)
        return sortAscending ? sorted : Array(sorted.reversed())
    }

    /// Priority-column rank: 0 = normal, 1 = some of the group throttled by us,
    /// 2 = the whole group in the background band.
    private func throttleRank(_ g: ProcGroup) -> Int {
        let t = g.procs.filter { store.record($0.pid) != nil }.count
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
