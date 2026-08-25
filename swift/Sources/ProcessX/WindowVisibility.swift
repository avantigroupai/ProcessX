import AppKit
import SwiftUI

/// Reports whether the window this view sits in is actually on screen.
///
/// ProcessX spends roughly nine tenths of its CPU redrawing its window, and
/// AppKit does *not* stop that work when the window is covered — measured, the
/// app fell only from 13.3% of a core to 9.9% the moment another window covered
/// it. The rasterisation stops; the SwiftUI graph pass and layout do not. So the
/// app has to ask, and stop publishing on its own.
///
/// It asks per window rather than via `NSApp.occlusionState`, because the
/// app-level answer is the union over every window — and the menu-bar extra owns
/// one, which is always visible. That would report "visible" forever.
struct WindowVisibilityReporter: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Reporter(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reporter: NSView {
        private let onChange: (Bool) -> Void
        /// Set from willClose, because at that point the window still reports
        /// itself visible and would otherwise keep the UI marked active.
        private var closing = false

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { onChange(false); return }
            closing = false
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(report(_:)), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(willClose(_:)),
                               name: NSWindow.willCloseNotification, object: window)
            report(nil)
        }

        @objc private func willClose(_ note: Notification?) {
            closing = true
            onChange(false)
        }

        @objc private func report(_ note: Notification?) {
            guard !closing, let window else { onChange(false); return }
            onChange(window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
