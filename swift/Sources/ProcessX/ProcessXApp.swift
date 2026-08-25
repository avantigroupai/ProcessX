import SwiftUI

/// Observes the title object rather than the whole monitor. Reading
/// `monitor.menuBarTitle` here would subscribe this label — and so the App's
/// whole body — to every change the monitor publishes, which is exactly the
/// coupling the hidden-window gate exists to break.
private struct MenuBarLabel: View {
    @ObservedObject var title: Monitor.MenuBarTitle
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg").symbolRenderingMode(.monochrome)
            Text(title.text).monospacedDigit()
        }
    }
}

@main
struct ProcessXApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // Headless verification paths; never reached in normal use.
        // @StateObject is lazy, so no Monitor/timer is created here.
        let args = CommandLine.arguments
        // The cap guardian: a second copy of this binary whose only job is to
        // outlive us and SIGCONT anything we left suspended. It must exit here,
        // before any NSApplication exists — it is not a second UI.
        if let i = args.firstIndex(of: "--cap-guardian"), i + 2 < args.count,
           let parent = pid_t(args[i + 1]) {
            CapGuardian.run(parent: parent, listPath: args[i + 2])
        }
        if args.contains("--selftest") { MainActor.assumeIsolated { SelfTest.run() } }
        // Headless cost breakdown of a sampling tick — no window, no view layer,
        // so it measures the sampler and nothing else.
        if let i = args.firstIndex(of: "--bench") {
            let n = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 20
            Bench.run(iterations: n)
        }
        if let i = args.firstIndex(of: "--bench-view") {
            let n = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 20
            MainActor.assumeIsolated { Bench.view(iterations: n) }
        }
        // The same Monitor the window drives, running for real with no view layer —
        // the control against which a window-open measurement is read.
        if let i = args.firstIndex(of: "--bench-live") {
            let n = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 20
            MainActor.assumeIsolated { Bench.live(seconds: n) }
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated {
                PreviewRender.run(to: args[i + 1], dark: args.contains("--dark"),
                                  rowsOnly: args.contains("--rows"),
                                  window: args.contains("--window"),
                                  expandBrowser: args.contains("--expand"))
            }
        }
    }

    var body: some Scene {
        // The real app: a normal window with a Dock icon.
        WindowGroup("ProcessX") {
            MainWindow(monitor: monitor)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { monitor.tick() }.keyboardShortcut("r")
            }
        }

        // Kept as a glance, not the main event — live CPU without raising the window.
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            MenuBarLabel(title: monitor.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
