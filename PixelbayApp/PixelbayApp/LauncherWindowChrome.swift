import AppKit
import SwiftUI
import PixelbayDesignSystem

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
    var isOnboarding: Bool = false

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let isBar = self.isBar
        let isOnboarding = self.isOnboarding
        let coordinator = context.coordinator
        // On the flip INTO bar mode the window still carries the prior route's
        // centred frame; hide it synchronously here — before SwiftUI repaints
        // the bar at that frame — so the centred ghost never shows. `apply`
        // (deferred below) repositions to bottom-centre and fades it back in.
        if isBar, coordinator.isEnteringBar(isBar), let window = nsView.window {
            window.alphaValue = 0
        }
        // Defer to the next runloop tick so the window exists and SwiftUI's
        // contentSize pass has set the new frame before we reposition.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            coordinator.apply(isBar: isBar, isOnboarding: isOnboarding, to: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var lastIsBar: Bool?
        private weak var pinnedWindow: NSWindow?
        private var resizeToken: NSObjectProtocol?
        private var revealItem: DispatchWorkItem?
        private var didReveal = false

        deinit { stopPinning() }

        /// True iff this update is the transition *into* bar mode (so the
        /// synchronous pre-hide in `updateNSView` only fires once per entry,
        /// not on every re-render while already a bar).
        func isEnteringBar(_ isBar: Bool) -> Bool { isBar && lastIsBar != true }

        func apply(isBar: Bool, isOnboarding: Bool, to window: NSWindow) {
            let changed = (lastIsBar != isBar)
            lastIsBar = isBar
            if !isBar { stopPinning() }   // bottom-pin only applies to the bar route
            if isBar {
                // Drop the title bar entirely. Keeping `.titled` (even with a
                // transparent, hidden titlebar + fullSizeContentView) leaves an
                // opaque titlebar strip rendered above the hover bar — the
                // "black bar" users see. Going borderless removes that strip;
                // the bar has no text fields so losing key-window status is
                // fine, and clicks/menus still work.
                window.styleMask.remove(.titled)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.styleMask.remove(.resizable)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false          // bar provides its own SwiftUI shadow
                // Dragging is driven by a SwiftUI gesture in PrecaptureView, NOT
                // AppKit's background drag: AppKit's drag loop blocks the runloop,
                // which stops the Liquid Glass backdrop from re-sampling and makes
                // the bar collapse to a flat opaque rectangle mid-drag.
                window.isMovableByWindowBackground = false
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.level = .floating
                // Keep the bar glued to bottom-centre across SwiftUI's
                // contentSize pass (and any later resize). See `pinBar`.
                pinBar(window, fadeIn: changed)
            } else if isOnboarding {
                // Onboarding draws a full-bleed neutral surface that must reach
                // the very top of the window — so the titlebar is transparent
                // with `fullSizeContentView`, and the window background matches
                // the surface (#181818) to avoid a flash on resize. Traffic
                // lights stay visible, floating over the dark content.
                window.styleMask.insert(.titled)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.styleMask.insert(.resizable)
                window.isOpaque = true
                window.backgroundColor = NSColor(red: 24/255, green: 24/255, blue: 24/255, alpha: 1)
                window.hasShadow = true
                window.isMovableByWindowBackground = false
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                window.level = .normal
                window.alphaValue = 1   // recover if a bar-mode fade was interrupted
                if changed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                        window?.center()
                    }
                }
            } else {
                window.styleMask.insert(.titled)   // restore chrome dropped in bar mode
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.styleMask.remove(.fullSizeContentView)   // undo onboarding's edge-to-edge
                window.styleMask.insert(.resizable)
                window.isOpaque = true
                window.backgroundColor = Theme.NSColor.bgBase   // neutral surface, matches content
                window.hasShadow = true
                window.isMovableByWindowBackground = false
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                window.level = .normal
                window.alphaValue = 1   // recover if a bar-mode fade was interrupted
                if changed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                        window?.center()
                    }
                }
            }
        }

        /// Pins the bar to bottom-centre and *holds* it there through SwiftUI's
        /// contentSize pass. The launcher window first appears at the prior
        /// route's centred frame, then shrinks to the bar's intrinsic size;
        /// AppKit anchors that resize at the top-left, so the window's bottom
        /// edge creeps up and the bar visibly jumps to the middle/top before a
        /// one-shot reposition can catch it. Re-pinning on *every* resize (not
        /// once on a timer) keeps it glued down. On a fresh transition we also
        /// hold it hidden until the layout settles, then fade it in in place.
        private func pinBar(_ window: NSWindow, fadeIn: Bool) {
            // The observer keeps the bar pinned through the contentSize resize.
            // It fires only on *resize* (not on moves), so it never fights the
            // user's drag-to-reposition gesture in PrecaptureView.
            installResizeObserver(on: window)
            guard fadeIn else {
                // Incidental re-render while already a bar (e.g. the picker's
                // permission poll): leave the frame ALONE so we don't yank a
                // user-dragged bar back to centre. Just guarantee it's visible.
                if window.alphaValue < 1 { window.alphaValue = 1 }
                return
            }
            // Fresh transition into bar mode: pin to bottom-centre, hold hidden
            // while the contentSize pass settles (the observer re-pins on each
            // interim resize), then fade in at the final spot.
            Self.positionBottomCentre(window)
            didReveal = false
            window.alphaValue = 0
            revealItem?.cancel()
            let item = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window else { return }
                self.reveal(window)
            }
            revealItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }

        private func installResizeObserver(on window: NSWindow) {
            guard pinnedWindow !== window else { return }
            stopPinning()
            pinnedWindow = window
            resizeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                Self.positionBottomCentre(window)
            }
        }

        private func reveal(_ window: NSWindow) {
            Self.positionBottomCentre(window)
            guard !didReveal else { return }
            didReveal = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
        }

        private func stopPinning() {
            revealItem?.cancel()
            revealItem = nil
            if let resizeToken { NotificationCenter.default.removeObserver(resizeToken) }
            resizeToken = nil
            pinnedWindow = nil
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
