import Foundation

/// v5 → v6 migrator (motion tuning overhaul). v6 replaces the project-wide
/// `zoomFollowStyle` macro sliders (float/speed/softness) with the flat
/// `tuning: TuningSettings` struct. There is no meaningful mapping from the
/// macro values to the new parameters — the macros fanned out into a
/// resolver that was retired along with them — so v5 documents simply start
/// from `TuningSettings.default` (the missing `tuning` key optional-decodes
/// to defaults).
///
/// The stale `zoomFollowStyle` key is dropped here so migrated documents
/// don't carry a dead field forward. Per-keyframe `extras` motion keys
/// (`zoomFollowTauRelaxed` etc.) are left in place — `extras` is a sparse
/// dictionary and unknown keys are inert.
public struct Migrator5To6: ProjectMigrator {
    public let fromVersion: Int = 5
    public let toVersion: Int = 6

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var json = json
        json.removeValue(forKey: "zoomFollowStyle")
        return json
    }
}
