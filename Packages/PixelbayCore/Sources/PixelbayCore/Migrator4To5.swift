import Foundation

/// v4 → v5 migrator (Phase 5 — Scenes). v4 projects have no `scenesSession`
/// field; v5 makes it an *optional* top-level value on `Project` (`nil` for
/// every pre-v5 project). The Codable optional-decode contract treats a
/// missing JSON key as `nil` on decode, so there is no field to stamp here —
/// we simply advance the schemaVersion stamp and rely on `Project`'s
/// synthesised decoder to fill `scenesSession = nil`.
///
/// We still register a no-op migrator so the chain runs end-to-end on every
/// load and the `currentSchemaVersion` bump is observable in tests. The
/// pattern matches the prior migrators' shape; future v5→v6 migrators slot in
/// the same way regardless of whether v5's payload arrives populated or nil.
///
/// Keys here must stay in lockstep with `Project`'s `CodingKeys`; if the
/// field is later renamed / restructured, write a fresh migrator vN → vN+1
/// rather than mutating this one.
public struct Migrator4To5: ProjectMigrator {
    public let fromVersion: Int = 4
    public let toVersion: Int = 5

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        // Intentionally a no-op: `scenesSession` is optional in v5, so a v4
        // document decodes cleanly as v5 with `scenesSession == nil`.
        return json
    }
}
