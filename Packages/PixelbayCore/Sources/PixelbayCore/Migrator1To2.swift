import Foundation

/// v1 → v2 migrator (Phase 3a). v1 projects have no `layout` field; v2 makes
/// it a top-level required field on `Project`. This migrator inserts the
/// Phase-1-default `LayoutPreset` so the visual output is unchanged after
/// migration — bottom-right PiP, 240×135 cam at the project's render
/// resolution, 12pt rounded rectangle, no background.
///
/// We intentionally insert the layout JSON inline as `[String: Any]` rather
/// than going through `LayoutPreset.encode(to:)`: the migrator runs before
/// the strict Codable decode, and the rest of the chain expects `[String: Any]`
/// shapes. The keys here must stay in lockstep with `LayoutPreset`'s
/// `CodingKeys` — if `LayoutPreset` is renamed / restructured, write a new
/// migrator vN → vN+1 rather than mutating this one.
public struct Migrator1To2: ProjectMigrator {
    public let fromVersion: Int = 1
    public let toVersion: Int = 2

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var result = json
        if result["layout"] == nil {
            result["layout"] = Self.defaultLayoutJSON()
        }
        return result
    }

    static func defaultLayoutJSON() -> [String: Any] {
        [
            "mode": [
                "kind": "pip",
                "position": "bottomRight",
                "size": "medium"
            ] as [String: Any],
            "camShape": "rectangle",
            "camCornerRadius": 12.0,
            "background": ["kind": "none"] as [String: Any],
            "padding": 0.0,
            "screenCornerRadius": 0.0,
            "extras": [String: Any]()
        ]
    }
}
