import Foundation

/// v7 → v8 migrator (free-form preview transform). v8 adds the
/// `LayoutMode.custom(screen:webcam:)` case so the user can drag/scale the
/// screen and webcam into a custom arrangement. Existing projects only ever
/// encoded `mode.kind ∈ {pip, splitHorizontal}`, both of which decode
/// unchanged under the v8 model — there is no on-disk shape to rewrite.
///
/// We still register a no-op migrator so the migration chain runs end-to-end
/// on every load and the `currentSchemaVersion` bump is observable in tests.
/// The pattern matches `Migrator4To5` (the prior additive-only step); future
/// v8→v9 migrators slot in the same way.
///
/// The version bump itself is load-bearing even though no payload changes: a
/// new enum case is not forward-compatible (an older Pixelbay throws when it
/// hits an unknown `"custom"` kind in `LayoutMode.init(from:)`), so stamping
/// v8 lets older builds reject these projects with the clean
/// `schemaVersionTooNew` "upgrade Pixelbay" message instead.
public struct Migrator7To8: ProjectMigrator {
    public let fromVersion: Int = 7
    public let toVersion: Int = 8

    public init() {}

    public func migrate(_ json: [String: Any]) throws -> [String: Any] {
        // Intentionally a no-op: pre-v8 layouts use only `.pip`/`.splitHorizontal`,
        // which decode cleanly under the v8 `LayoutMode`. The `.custom` case is
        // only ever produced by v8+ builds.
        return json
    }
}
