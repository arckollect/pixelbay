import AppKit
import SwiftUI

// Restyles the launcher's NSWindow per route. In `isBar` mode (the New
// Recording picker) the window becomes a Screen-Studio-style floating bar:
// no title bar / traffic lights, transparent + shadowless (the SwiftUI bar
// draws its own rounded background + shadow), floating level, movable by
// background, positioned bottom-centre of the active screen. For every other
// route (onboarding, recording placeholder, post-capture) it restores normal
// titled-window chrome.
//
// Paired with `.windowResizability(.contentSize)` on the launcher Scene so the
// window tracks each route's content size — the bar route is intrinsically
// sized, the others carry their own `.frame(minWidth:minHeight:)`.
//
// Dropped into `.background(...)` of the launcher content so it can reach the
// hosting window without owning layout.
struct LauncherWindowChrome: NSViewRepresentable {
    let isBar: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let isBar = self.isBar
        let coordinator = context.coordinator
        // Defer to the next runloop tick so the window exists and SwiftUI's
        // contentSize pass has set the new frame before we reposition.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            coordinator.apply(isBar: isBar, to: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var lastIsBar: Bool?

        func apply(isBar: Bool, to window: NSWindow) {
            let changed = (lastIsBar != isBar)
            lastIsBar = isBar
            if isBar {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.styleMask.remove(.resizable)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false          // bar provides its own SwiftUI shadow
                window.isMovableByWindowBackground = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.level = .floating
                if changed {
                    // Reposition after the contentSize resize settles so we
                    // centre the *bar's* frame, not the prior route's.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                        guard let window else { return }
                        Self.positionBottomCentre(window)
                    }
                }
            } else {
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.styleMask.insert(.resizable)
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.hasShadow = true
                window.isMovableByWindowBackground = false
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                window.level = .normal
                if changed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                        window?.center()
                    }
                }
            }
        }

        private static func positionBottomCentre(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = window.frame.size
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 24
            )
            window.setFrameOrigin(origin)
        }
    }
}
