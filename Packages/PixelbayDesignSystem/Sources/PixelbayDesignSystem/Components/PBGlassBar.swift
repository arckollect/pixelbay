import SwiftUI

// The app's floating "Liquid Glass" recipe, promoted out of the private
// copies previously duplicated in PrecaptureView and RecordingHUD (and now
// also used by the editor's floating preview transport).
//
// Deliberately NOT macOS 26's `.glassEffect` — that re-samples the desktop
// backdrop every frame and renders broken (a flat opaque rectangle, no tint
// or shape) whenever sampling stalls (window drag, window-style change).
// `NSVisualEffectView`-backed materials are rock-solid across drags,
// occlusion and style changes, so this stacks `.ultraThinMaterial` + a dark
// wash + a faint top white sheen, all clipped to the caller's shape. The
// host should sit on a borderless/clear window (or any surface) — the
// material samples whatever is behind it.

public extension View {
    /// Fills the view's background with the app's frosted-glass recipe,
    /// clipped to `shape`. Pair with a white-rim overlay
    /// (`shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)`) for edge
    /// separation on light backdrops.
    func pbGlassBar<S: Shape>(_ shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.28))
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
        }
    }
}
