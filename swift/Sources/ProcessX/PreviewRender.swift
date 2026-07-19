import AppKit
import Foundation
import SwiftUI

/// `ProcessX --render <path.png>` — renders the real menu content with real live
/// data to a PNG, so the layout can be inspected without a display session.
/// Materials/vibrancy don't rasterise here, but layout, text and structure do.
@MainActor
enum PreviewRender {
    static func run(to path: String, dark: Bool, rowsOnly: Bool = false, window: Bool = false) {
        let monitor = Monitor()
        monitor.tick()                          // establish the CPU baseline
        Thread.sleep(forTimeInterval: 1.2)
        monitor.tick()                          // real interval data

        // Give the sparklines a couple of points of history to draw.
        for _ in 0..<3 { Thread.sleep(forTimeInterval: 0.35); monitor.tick() }

        let inner: AnyView
        if window {
            inner = AnyView(MainWindow(monitor: monitor).frame(width: 1180, height: 800))
        } else if rowsOnly {
            inner = AnyView(VStack(spacing: 0) {
                ForEach(monitor.visibleGroups.prefix(10)) { g in
                    BigGroupRow(group: g, monitor: monitor, accent: monitor.theme.accent)
                    Divider().opacity(0.4)
                }
            }.frame(width: 1180))
        } else {
            inner = AnyView(MenuContent(monitor: monitor))
        }

        let view = AnyView(
            inner
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color(white: 0.12) : Color(white: 0.96))
        )

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("rendered \(Int(image.size.width))x\(Int(image.size.height)) -> \(path)")
            print("groups shown: \(monitor.visibleGroups.count), cpu: \(monitor.menuBarTitle)")
        } catch {
            print("write failed: \(error)")
            exit(1)
        }
        exit(0)
    }
}
