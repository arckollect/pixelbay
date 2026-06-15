import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The app's floating "Liquid Glass" recipe, promoted out of the private
// copies previously duplicated in PrecaptureView and RecordingHUD (and now
// also used by the editor's floating preview transport).
//
// Deliberately NOT macOS 26's `.glassEffect` — that re-samples the desktop
// backdrop every frame and renders broken (a flat opaque rectangle, no tint
// or shape) whenever sampling stalls (window drag, window-style change).
// `NSVisualEffectView`-backed materials are rock-solid across drags,
// occlusion and style changes. The host should sit on a borderless/clear
// window (or any surface) — the material samples whatever is behind it.

public extension View {
    /// Fills the view's background with the app's frosted-glass recipe,
    /// clipped to `shape`. Pair with a white-rim overlay
    /// (`shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)`) for edge
    /// separation on light backdrops.
    func pbGlassBar<S: Shape>(_ shape: S) -> some View {
        background {
            ZStack {
#if canImport(AppKit)
                PBGlassBackdrop()
                    .clipShape(shape)
#else
                shape.fill(.ultraThinMaterial)
#endif
                shape.fill(Color.black.opacity(0.015))
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.05),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }
}

#if canImport(AppKit)
private struct PBGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}
#endif
