import Foundation

/// v3 → v4 migrator (Phase 3c). v3 projects have no `cursorSettings` field;
/// v4 makes it a required top-level value on `Project` with the standard
/// default (synthetic cursor enabled, default scale). We stamp the default on
/// load — legacy assets keep their existing OS-baked-in cursor because the
/// compositor additionally gates on each `MediaAsset.cursorRenderedSynthetically`
/// (stored in `extras`), which only new captures set.
///
/// Keys here must stay in lockstep with `Project`'s `CodingKeys`; if the
/// field is later renamed / restructured, write a fresh migrator vN → vN+1
/// rather than mutating this one.
public struct Migrator3To4: ProjectMigrator {
    public let fromVersion: Int = 3
    public let toVersion: Int = 4

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var result = json
        if result["cursorSettings"] == nil {
            result["cursorSettings"] = [
                "isEnabled": true,
                "scale": CursorSettings.defaultScale,
                "extras": [String: Any]()
            ] as [String: Any]
        }
        return result
    }
}
