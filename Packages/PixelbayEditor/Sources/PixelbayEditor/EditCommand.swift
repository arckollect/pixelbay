import Foundation
import PixelbayCore

// Pure-data editor model. Phase 2's headline feature is a real timeline; this
// package owns the operations that mutate a Project (slice / trim / drag /
// volume / speed / overlays) plus the undo/redo machinery they fold into.
//
// Design choices, applicable through Phase 2:
//
//   1. Operations are CommanD instances that `apply(to: &Project)` and return
//      their own inverse. Pure-functional in spirit — no captured mutable
//      state on the command itself, the Project owns the truth.
//   2. `EditHistory` actor wraps the Project + push/pop undo/redo stacks.
//      Each apply() drains the redo stack (linear-history model — branches
//      ship in Phase 4 if at all).
//   3. Commands are NOT generally Codable. The schema records the resulting
//      `Project` state, not the history (HANDOFF §2.3 — every change goes
//      through `bundleVersion` / `schemaVersion` migrators if the *shape*
//      changes; ops are session state, not document state).
//   4. Commands stay Sendable so they cross actor boundaries (the editor's
//      view models are @MainActor; EditHistory itself is an actor).
//
// Phase 4+ may revisit (1) for fine-grained drag interactions, but the v0.1
// trim/split/move/volume/speed set is comfortably command-shaped.

/// An atomic, reversible mutation of a `Project`. Invariant: a freshly-applied
/// command's returned inverse, applied to the post-state, exactly restores
/// the pre-state. Tests pin this round-trip per command.
public protocol EditCommand: Sendable {
    /// Human-readable, used by Edit menu undo/redo strings. Phase 2's UI will
    /// substitute these into "Undo X" / "Redo X" menu items.
    var displayName: String { get }

    /// Apply the command to `project` in place and return the inverse —
    /// i.e. a command that, applied to the post-state, restores the
    /// pre-state. The inverse must be self-contained (capture whatever
    /// pre-state values it needs at apply time).
    @discardableResult
    func apply(to project: inout Project) throws -> any EditCommand
}

public enum EditError: Error, LocalizedError, Equatable {
    case clipNotFound(ClipID)
    case trackNotFound(TrackID)
    case invalidSourceRange(reason: String)
    case invalidTimelineRange(reason: String)
    case invalidVolume(value: Double)
    case invalidSpeed(value: Double)

    public var errorDescription: String? {
        switch self {
        case .clipNotFound(let id):
            return "Clip not found: \(id.rawValue)"
        case .trackNotFound(let id):
            return "Track not found: \(id.rawValue)"
        case .invalidSourceRange(let reason):
            return "Invalid source range: \(reason)"
        case .invalidTimelineRange(let reason):
            return "Invalid timeline range: \(reason)"
        case .invalidVolume(let v):
            return "Invalid volume: \(v) (must be ≥ 0)"
        case .invalidSpeed(let v):
            return "Invalid speed: \(v) (must be > 0)"
        }
    }
}
