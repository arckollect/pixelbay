import Foundation

// One-time auto-zoom marker. Mirrors OpenScreen's "on-load auto-suggest pass":
// the first time a freshly-captured project opens in the editor, the dwell-
// based zoom generator runs automatically. This flag records that it has run
// so the pass never fires twice — if the user later curates or deletes the
// generated zooms, reopening won't re-add them.
//
// Stored in `Project.extras` as a JSON bool (no schema bump), the same typed-
// accessor pattern as `MediaAsset.cursorRenderedSynthetically`. Missing key reads as `false`, so
// every pre-existing project is treated as "not yet auto-zoomed" — but the
// editor also gates the pass on the project having no zoom effects yet, so
// curated older projects are left untouched.

public extension Project {
    var autoZoomGenerated: Bool {
        get {
            if case .bool(let value) = extras["autoZoomGenerated"] { return value }
            return false
        }
        set {
            if newValue {
                extras["autoZoomGenerated"] = .bool(true)
            } else {
                extras["autoZoomGenerated"] = nil
            }
        }
    }
}
