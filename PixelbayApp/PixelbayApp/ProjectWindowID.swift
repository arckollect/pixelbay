import Foundation

// Value identifier passed to WindowGroup(for: ProjectWindowID.self).
//
// SwiftUI persists this across launches via window-state restoration, so we
// keep it minimal: just the bundle URL. URL is Codable + Hashable + Sendable
// out of the box on macOS 14, which is everything WindowGroup(for:) needs.
//
// Wrapping URL in a typed struct (vs. binding the group directly to URL) lets
// us evolve the identity later — e.g. add a `displayHint` for window titles
// before the document loads — without changing every call site, and keeps
// ProjectWindowID-keyed state distinct from any other URL-keyed scenes we
// might add later.
struct ProjectWindowID: Hashable, Codable, Sendable {
    let bundleURL: URL
}
