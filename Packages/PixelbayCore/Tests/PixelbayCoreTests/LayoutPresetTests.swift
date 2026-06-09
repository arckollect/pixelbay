import XCTest
@testable import PixelbayCore

final class LayoutPresetTests: XCTestCase {

    // MARK: - Defaults

    func test_phase1Default_matchesPhase1Look() {
        let p = LayoutPreset.phase1Default
        switch p.mode {
        case .pip(let position, let size):
            XCTAssertEqual(position, .bottomRight)
            XCTAssertEqual(size, .medium)
        case .splitHorizontal:
            XCTFail("phase1Default must be a PiP")
        }
        XCTAssertEqual(p.camShape, .rectangle)
        XCTAssertEqual(p.camCornerRadius, 12)
        XCTAssertEqual(p.background, .none)
        XCTAssertEqual(p.padding, 0)
        XCTAssertEqual(p.screenCornerRadius, 0)
    }

    func test_project_defaultsToPhase1Layout() {
        let project = Project(name: "default")
        XCTAssertEqual(project.layout, .phase1Default)
    }

    // MARK: - Codable round-trip (each enum branch)

    func test_pipMode_roundTripsThroughCodable() throws {
        try roundTripMode(.pip(position: .center, size: .large))
    }

    func test_splitMode_roundTripsThroughCodable() throws {
        try roundTripMode(.splitHorizontal(screenSide: .left, screenFraction: 0.7))
    }

    func test_background_solid_roundTripsThroughCodable() throws {
        try roundTripBackground(.solid(color: RGBColor(r: 0.2, g: 0.4, b: 0.8)))
    }

    func test_background_gradient_roundTripsThroughCodable() throws {
        try roundTripBackground(
            .gradient(from: .black, to: RGBColor(r: 0.1, g: 0.1, b: 0.3))
        )
    }

    func test_background_systemWallpaper_roundTripsThroughCodable() throws {
        try roundTripBackground(.systemWallpaper(fallback: .black))
    }

    func test_background_none_roundTripsThroughCodable() throws {
        try roundTripBackground(.none)
    }

    func test_background_image_builtin_roundTripsThroughCodable() throws {
        try roundTripBackground(.image(.builtin(id: "Drift", name: "Drift")))
    }

    func test_background_image_upload_roundTripsThroughCodable() throws {
        try roundTripBackground(.image(.upload(relativePath: "backgrounds/my-bg.png", name: "My BG")))
    }

    func test_background_wallpaper_roundTripsThroughCodable() throws {
        try roundTripBackground(.wallpaper(WallpaperGradient(
            name: "Aurora",
            base: RGBColor(r: 0.05, g: 0.06, b: 0.13),
            blobs: [
                WallpaperGradient.Blob(color: RGBColor(r: 0.2, g: 0.4, b: 0.9, a: 0.9), x: 0.18, y: 0.2, radius: 0.95),
                WallpaperGradient.Blob(color: RGBColor(r: 0.5, g: 0.2, b: 0.85, a: 0.85), x: 0.82, y: 0.85, radius: 1.0),
            ]
        )))
    }

    func test_decodeLegacyLayout_missingDefaultedFields_usesLayoutDefaults() throws {
        let json = """
        {
          "mode": {
            "kind": "pip",
            "position": "bottomRight",
            "size": "medium"
          },
          "background": { "kind": "none" }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: json)

        XCTAssertEqual(decoded.mode, .pip(position: .bottomRight, size: .medium))
        XCTAssertEqual(decoded.camShape, .rectangle)
        XCTAssertEqual(decoded.camCornerRadius, 12)
        XCTAssertEqual(decoded.background, .none)
        XCTAssertEqual(decoded.padding, 0)
        XCTAssertEqual(decoded.screenCornerRadius, 0)
        XCTAssertEqual(decoded.extras, [:])
    }

    // MARK: - Migrator v1 → v2

    func test_migrator_addsLayoutPresetToV1Document() throws {
        let v1: [String: Any] = [
            "schemaVersion": 1,
            "bundleVersion": 1,
            "id": "p1",
            "name": "Migration test",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v1)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)
        let layout = try XCTUnwrap(migrated["layout"] as? [String: Any])
        let mode = try XCTUnwrap(layout["mode"] as? [String: Any])
        XCTAssertEqual(mode["kind"] as? String, "pip")
        XCTAssertEqual(mode["position"] as? String, "bottomRight")
        XCTAssertEqual(mode["size"] as? String, "medium")
        XCTAssertEqual(layout["camShape"] as? String, "rectangle")
        XCTAssertEqual(layout["camCornerRadius"] as? Double, 12.0)
    }

    func test_migrator_decodesAfterMigration_yieldsPhase1Default() throws {
        // End-to-end: migrate raw v1 JSON → re-encode → decode as Project →
        // project.layout equals phase1Default. This is what
        // ProjectBundleStore.load runs every time it opens a pre-Phase-3a
        // .pixelbay bundle.
        let v1: [String: Any] = [
            "schemaVersion": 1,
            "bundleVersion": 1,
            "id": "p1",
            "name": "Migration test",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v1)
        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(project.schemaVersion, currentSchemaVersion)
        XCTAssertEqual(project.layout, .phase1Default)
    }

    func test_migrator_preservesUserSetLayoutIfPresent() throws {
        // A v1 document that already happens to carry a `layout` field (e.g.
        // because the user manually edited project.json, or because a future
        // version of Pixelbay wrote one without bumping the schema) should
        // not be clobbered. Phase 3a's migrator only ADDs missing layout.
        let v1: [String: Any] = [
            "schemaVersion": 1,
            "bundleVersion": 1,
            "id": "p1",
            "name": "Pre-existing layout",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:],
            "layout": [
                "mode": [
                    "kind": "pip",
                    "position": "topLeft",
                    "size": "large"
                ] as [String: Any],
                "camShape": "circle",
                "camCornerRadius": 0.0,
                "background": ["kind": "solid", "color": ["r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0]] as [String: Any],
                "padding": 40.0,
                "screenCornerRadius": 16.0,
                "extras": [String: Any]()
            ]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v1)
        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        switch project.layout.mode {
        case .pip(let pos, let size):
            XCTAssertEqual(pos, .topLeft)
            XCTAssertEqual(size, .large)
        default:
            XCTFail("expected PiP")
        }
        XCTAssertEqual(project.layout.camShape, .circle)
        XCTAssertEqual(project.layout.padding, 40)
    }

    // MARK: - Helpers

    private func roundTripMode(_ mode: LayoutMode, file: StaticString = #filePath, line: UInt = #line) throws {
        let preset = LayoutPreset(mode: mode)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        XCTAssertEqual(decoded, preset, file: file, line: line)
    }

    private func roundTripBackground(_ background: Background, file: StaticString = #filePath, line: UInt = #line) throws {
        let preset = LayoutPreset(background: background)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: data)
        XCTAssertEqual(decoded, preset, file: file, line: line)
    }
}
