import Foundation

// Migrators operate on the raw JSON object (parsed by JSONSerialization) before
// the strict Codable decode step. This is intentional: a v1 project read by a
// v3 binary may contain fields the current `Project` struct rejects or
// transforms. The migrator chain rewrites those fields before final decode.
//
// Each migrator advances the document by exactly one schema version
// (fromVersion -> fromVersion + 1). On load, we run them in sequence:
//
//   docVersion = json["schemaVersion"]
//   while docVersion < currentSchemaVersion:
//       migrator = registry[docVersion]
//       json = migrator.migrate(json)
//       docVersion += 1
//
// Adding a new schema version means: bump `currentSchemaVersion`, write a new
// `MigratorN_to_N1` type, and append it to `MigrationRegistry.allMigrators`.

public protocol ProjectMigrator: Sendable {
    var fromVersion: Int { get }
    var toVersion: Int { get }
    func migrate(_ json: [String: Any]) throws -> [String: Any]
}

public enum MigrationError: Error, CustomStringConvertible {
    case missingSchemaVersion
    case schemaVersionTooNew(found: Int, supported: Int)
    case noMigratorAvailable(from: Int)
    case migratorChainBroken(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .missingSchemaVersion:
            return "project.json is missing schemaVersion"
        case .schemaVersionTooNew(let found, let supported):
            return "project.json schemaVersion \(found) is newer than supported max \(supported); upgrade Pixelbay"
        case .noMigratorAvailable(let from):
            return "no migrator registered to advance schemaVersion from \(from)"
        case .migratorChainBroken(let expected, let got):
            return "migrator chain broken: expected migrator producing v\(expected) but produced v\(got)"
        }
    }
}

public struct MigrationRegistry: Sendable {
    public let migrators: [ProjectMigrator]

    public init(migrators: [ProjectMigrator]) {
        self.migrators = migrators.sorted { $0.fromVersion < $1.fromVersion }
    }

    public static let standard: MigrationRegistry = MigrationRegistry(migrators: [
        Migrator1To2(),
        Migrator2To3(),
        Migrator3To4(),
        Migrator4To5(),
        Migrator5To6(),
    ])

    public func migrate(_ raw: [String: Any]) throws -> [String: Any] {
        guard let initialVersion = raw["schemaVersion"] as? Int else {
            throw MigrationError.missingSchemaVersion
        }
        if initialVersion > currentSchemaVersion {
            throw MigrationError.schemaVersionTooNew(found: initialVersion, supported: currentSchemaVersion)
        }

        var current = raw
        var version = initialVersion
        while version < currentSchemaVersion {
            guard let migrator = migrators.first(where: { $0.fromVersion == version }) else {
                throw MigrationError.noMigratorAvailable(from: version)
            }
            current = try migrator.migrate(current)
            let nextVersion = version + 1
            if migrator.toVersion != nextVersion {
                throw MigrationError.migratorChainBroken(expected: nextVersion, got: migrator.toVersion)
            }
            current["schemaVersion"] = nextVersion
            version = nextVersion
        }
        return current
    }
}
