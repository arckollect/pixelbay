import Foundation
import Observation
import OSLog
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ScenesAppendTarget")

// Slice A.2 — shared inter-window state that says: "the next time the
// Scenes window opens, it should be wired against THIS editor document
// instead of starting fresh." The editor toolbar's "Scenes" button sets
// the target before calling `openWindow(id: WindowID.scenes)`; the
// ScenesWindowView reads it on appear and hands it to ScenesSessionModel.
//
// Why a shared singleton rather than a window-open value? The scenes
// window is declared as `Window` (singleton), not `WindowGroup(for:)`, so
// SwiftUI doesn't accept a Hashable Value at open time. The editor and the
// scenes window live in different Scene declarations and can't otherwise
// share a SwiftUI-owned reference type cleanly. An `@Observable`
// `ScenesAppendTarget` instance injected at App level via `.environment`
// gives both surfaces a stable, mutation-observable bridge with no
// NotificationCenter dance.
//
// Lifecycle: set the bundleURL before opening the window; ScenesWindowView
// captures it on appear (snapshotting into the model so subsequent
// mutations to the singleton don't leak between sessions). Clear after
// the window closes or the merge completes.

@MainActor
@Observable
final class ScenesAppendTarget {
    /// When non-nil, the next ScenesWindowView appear opens the model in
    /// "append to this editor document" mode. The bundleURL is dereferenced
    /// to a `ProjectBundle` + `ProjectDocument`-equivalent at load time, so
    /// races between editor save/close and the scenes window opening are
    /// safe — the worst case is the user sees the History section empty
    /// (the bundle no longer exists or has no clips).
    var bundleURL: URL?

    /// Sets the bundleURL and logs the transition. The editor's "Scenes"
    /// toolbar button calls this immediately before
    /// `openWindow(id: WindowID.scenes)` so the in-flight window-open sees
    /// the target.
    func set(_ url: URL?) {
        bundleURL = url
        if let url {
            log.info("scenes-append-target set: \(url.path, privacy: .public)")
        } else {
            log.info("scenes-append-target cleared")
        }
    }
}
