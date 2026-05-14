import Foundation

/// v2 → v3 migrator (Phase 3b). v2 projects have no `effects` field; v3
/// makes it a required top-level array on `Project` (default `[]`). We
/// stamp an empty array on load — preserves prior visual output for any
/// project that didn't have effects in v2.
///
/// Keys here must stay in lockstep with `Project`'s `CodingKeys`; if the
/// field is later renamed / restructured, write a fresh migrator vN → vN+1
/// rather than mutating this one (the chain is replay-anchored on the
/// fromVersion field).
public struct Migrator2To3: ProjectMigrator {
    public let fromVersion: Int = 2
    public let toVersion: Int = 3

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var result = json
        if result["effects"] == nil {
            result["effects"] = [Any]()
        }
        return result
    }
}
