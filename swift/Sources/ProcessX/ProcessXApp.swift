import SwiftUI

@main
struct ProcessXApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // Headless verification paths; never reached in normal use.
        // @StateObject is lazy, so no Monitor/timer is created here.
        let args = CommandLine.arguments
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
