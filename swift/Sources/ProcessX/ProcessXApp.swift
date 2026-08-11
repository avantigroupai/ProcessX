import SwiftUI

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
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated {
                PreviewRender.run(to: args[i + 1], dark: args.contains("--dark"),
                                  rowsOnly: args.contains("--rows"),
                                  window: args.contains("--window"))
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
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg").symbolRenderingMode(.monochrome)
                Text(monitor.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
