import XCTest
@testable import PixelbayCore

final class ScenesSessionTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_scenesSession_roundTripsThroughCodable_withTakes() throws {
        let assetID = MediaAssetID.generate()
        let take = Take(
            sessionID: "abcd1234",
            assetIDs: [assetID],
            durationSeconds: 12.5,
            thumbnailRelativePath: "media/thumb-abcd1234.png"
        )
        let scene = Scene(
            description: "Intro",
            sourceOverride: SceneSourceOverride(displayID: 42, includeSystemAudio: true),
            takes: [take],
            activeTakeIndex: 0
        )
        let session = ScenesSession(
            defaults: ScenesGlobalDefaults(
                displayID: 7,
                cameraUniqueID: "cam-xyz",
                micUniqueID: "mic-abc",
                includeSystemAudio: false,
                logClicks: true
            ),
            scenes: [scene]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ScenesSession.self, from: data)

        XCTAssertEqual(decoded.defaults.displayID, 7)
        XCTAssertEqual(decoded.defaults.cameraUniqueID, "cam-xyz")
        XCTAssertEqual(decoded.scenes.count, 1)
        XCTAssertEqual(decoded.scenes[0].description, "Intro")
        XCTAssertEqual(decoded.scenes[0].sourceOverride.displayID, 42)
        XCTAssertEqual(decoded.scenes[0].sourceOverride.includeSystemAudio, true)
        XCTAssertEqual(decoded.scenes[0].takes.count, 1)
        XCTAssertEqual(decoded.scenes[0].takes[0].sessionID, "abcd1234")
        XCTAssertEqual(decoded.scenes[0].takes[0].assetIDs, [assetID])
        XCTAssertEqual(decoded.scenes[0].takes[0].durationSeconds, 12.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.scenes[0].takes[0].thumbnailRelativePath, "media/thumb-abcd1234.png")
        XCTAssertEqual(decoded.scenes[0].activeTakeIndex, 0)
        XCTAssertEqual(decoded.scenes[0].activeTake?.sessionID, "abcd1234")
    }

    func test_scene_activeTake_returnsNilWhenIndexOutOfBounds() {
        // Defensive — we never write an out-of-range activeTakeIndex, but the
        // accessor must not crash if a malformed document lands.
        let scene = Scene(takes: [], activeTakeIndex: 0)
        XCTAssertNil(scene.activeTake)

        let badScene = Scene(
            takes: [Take(sessionID: "xx")],
            activeTakeIndex: 5
        )
        XCTAssertNil(badScene.activeTake)
    }

    func test_sceneSourceOverride_hasAnyOverride_reflectsAnyNonNilField() {
        XCTAssertFalse(SceneSourceOverride().hasAnyOverride)
        XCTAssertTrue(SceneSourceOverride(displayID: 1).hasAnyOverride)
        XCTAssertTrue(SceneSourceOverride(cameraUniqueID: "x").hasAnyOverride)
        XCTAssertTrue(SceneSourceOverride(micUniqueID: "y").hasAnyOverride)
        XCTAssertTrue(SceneSourceOverride(includeSystemAudio: true).hasAnyOverride)
        XCTAssertTrue(SceneSourceOverride(includeSystemAudio: false).hasAnyOverride)
    }

    func test_scenesSession_freshDefault_emitsFiveEmptyScenes() {
        let session = ScenesSession.freshDefault()
        XCTAssertEqual(session.scenes.count, 5)
        for scene in session.scenes {
            XCTAssertTrue(scene.takes.isEmpty)
            XCTAssertNil(scene.activeTakeIndex)
            XCTAssertEqual(scene.description, "")
            XCTAssertFalse(scene.sourceOverride.hasAnyOverride)
        }
    }

    // MARK: - Project schema v5 integration

    func test_project_schemaVersion_isFive() {
        XCTAssertEqual(currentSchemaVersion, 5)
    }

    func test_project_freshProject_scenesSessionIsNil() {
        let project = Project(name: "Plain")
        XCTAssertNil(project.scenesSession)
    }

    func test_project_withScenesSession_roundTripsThroughCodable() throws {
        let session = ScenesSession.freshDefault()
        let project = Project(name: "Scenes bundle", scenesSession: session)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(project)
        let decoded = try decoder.decode(Project.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, currentSchemaVersion)
        XCTAssertNotNil(decoded.scenesSession)
        XCTAssertEqual(decoded.scenesSession?.scenes.count, 5)
    }

    // MARK: - Migrator v4 → v5

    func test_migrator4To5_decodesPreV5DocumentWithNilScenesSession() throws {
        // A v4 project written by an older Pixelbay binary has no
        // `scenesSession` key. The chain should advance it to v5 and the
        // resulting Project should decode with scenesSession == nil.
        let v4Document: [String: Any] = [
            "schemaVersion": 4,
            "bundleVersion": 1,
            "id": "p4-test",
            "name": "Pre-scenes project",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "layout": Migrator1To2.defaultLayoutJSON(),
            "effects": [],
            "cursorSettings": [
                "isEnabled": true,
                "scale": 3.25,
                "extras": [String: Any]()
            ] as [String: Any],
            "extras": [String: Any]()
        ]

        let migrated = try MigrationRegistry.standard.migrate(v4Document)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 5)

        // The migrated dict must decode straight into Project with
        // scenesSession == nil because the field is optional.
        let data = try JSONSerialization.data(withJSONObject: migrated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertNil(project.scenesSession)
    }

    func test_migrator4To5_passesThroughExistingScenesSession() throws {
        let session = ScenesSession.freshDefault()
        let sessionData = try JSONEncoder().encode(session)
        let sessionJSON = try JSONSerialization.jsonObject(with: sessionData)

        let v4WithEarlyScenesSession: [String: Any] = [
            "schemaVersion": 4,
            "scenesSession": sessionJSON
        ]
        let migrated = try Migrator4To5().migrate(v4WithEarlyScenesSession)
        XCTAssertNotNil(migrated["scenesSession"])
    }

    func test_migratorChain_advancesV1ThroughV5() throws {
        let v1Document: [String: Any] = [
            "schemaVersion": 1,
            "bundleVersion": 1,
            "id": "p1",
            "name": "v1 doc",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v1Document)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 5)

        let data = try JSONSerialization.data(withJSONObject: migrated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(project.schemaVersion, 5)
        XCTAssertNil(project.scenesSession)
    }
}
