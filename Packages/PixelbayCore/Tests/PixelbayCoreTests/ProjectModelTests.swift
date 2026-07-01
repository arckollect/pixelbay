import XCTest
@testable import PixelbayCore

final class ProjectModelTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_project_roundTripsThroughCodable() throws {
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen-001.mov",
            captureStart: .seconds(0),
            nativeDuration: .seconds(30)
        )
        let clip = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: .seconds(2), duration: .seconds(20)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(20))
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clip])
        let project = Project(
            name: "Demo",
            assets: [asset],
            tracks: [track],
            sourceSegments: [
                SourceSegment(
                    assetID: asset.id,
                    timelineRange: TimeRange(start: .zero, duration: .seconds(20))
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(project)
        let decoded = try decoder.decode(Project.self, from: data)

        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.schemaVersion, currentSchemaVersion)
        XCTAssertEqual(decoded.assets.count, 1)
        XCTAssertEqual(decoded.tracks.count, 1)
        XCTAssertEqual(decoded.tracks[0].clips.count, 1)
        XCTAssertEqual(decoded.tracks[0].clips[0].sourceRange.start.seconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(decoded.tracks[0].clips[0].sourceRange.duration.seconds, 20.0, accuracy: 1e-9)
        XCTAssertEqual(decoded.sourceSegments.count, 1)
        XCTAssertEqual(decoded.tuning, .default)
    }

    func test_decodeLegacyProject_missingDefaultedFields_usesModelDefaults() throws {
        let json = """
        {
          "schemaVersion": 5,
          "id": "project-legacy",
          "name": "Legacy",
          "createdAt": "2026-05-01T00:00:00Z",
          "modifiedAt": "2026-05-01T00:00:00Z",
          "assets": [
            {
              "id": "asset-screen",
              "kind": "display",
              "relativePath": "media/screen.mov",
              "nativeDuration": { "value": 6000, "timescale": 600 }
            }
          ],
          "tracks": [
            {
              "id": "track-screen",
              "kind": "screen",
              "name": "Screen",
              "clips": [
                {
                  "id": "clip-screen",
                  "assetID": "asset-screen",
                  "sourceRange": {
                    "start": { "value": 0, "timescale": 600 },
                    "duration": { "value": 6000, "timescale": 600 }
                  },
                  "timelineRange": {
                    "start": { "value": 0, "timescale": 600 },
                    "duration": { "value": 6000, "timescale": 600 }
                  }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: json)

        XCTAssertEqual(project.bundleVersion, currentBundleVersion)
        XCTAssertTrue(project.sourceSegments.isEmpty)
        XCTAssertEqual(project.layout, .phase1Default)
        XCTAssertTrue(project.effects.isEmpty)
        XCTAssertEqual(project.tuning, .default)
        XCTAssertEqual(project.cursorSettings, .default)
        XCTAssertNil(project.scenesSession)
        XCTAssertEqual(project.extras, [:])
        XCTAssertEqual(project.assets.first?.extras, [:])
        XCTAssertFalse(project.tracks[0].muted)
        XCTAssertFalse(project.tracks[0].hidden)
        XCTAssertEqual(project.tracks[0].extras, [:])
        let clip = project.tracks[0].clips[0]
        XCTAssertEqual(clip.volume, 1)
        XCTAssertEqual(clip.speed, 1)
        XCTAssertTrue(clip.enabled)
        XCTAssertEqual(clip.extras, [:])
    }

    func test_project_customTuning_roundTripsThroughCodable() throws {
        var project = Project(name: "Motion tuning")
        project.tuning = TuningSettings(
            cameraTau: 0.55,
            settle: 0.8,
            deadzoneFraction: 0.2,
            edgeCushion: 0.7,
            fastMotionSensitivity: 0.4,
            smoothingScope: .zoomsOnly,
            shutterAngle: 270
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded.tuning, project.tuning)
    }

    func test_tuningSettings_clampOnInitAndMutation() {
        var tuning = TuningSettings(
            cameraTau: 99,
            settle: -1,
            deadzoneFraction: 99,
            edgeCushion: -1,
            maxPanSpeed: 0,
            fastMotionSensitivity: 99,
            shutterAngle: 999
        )
        XCTAssertEqual(tuning.cameraTau, TuningSettings.cameraTauRange.upperBound)
        XCTAssertEqual(tuning.settle, TuningSettings.settleRange.lowerBound)
        XCTAssertEqual(tuning.deadzoneFraction, TuningSettings.deadzoneFractionRange.upperBound)
        XCTAssertEqual(tuning.edgeCushion, TuningSettings.edgeCushionRange.lowerBound)
        XCTAssertEqual(tuning.maxPanSpeed, TuningSettings.maxPanSpeedRange.lowerBound)
        XCTAssertEqual(tuning.fastMotionSensitivity, TuningSettings.fastMotionSensitivityRange.upperBound)
        XCTAssertEqual(tuning.shutterAngle, TuningSettings.shutterAngleRange.upperBound)

        tuning.pathWindowSeconds = 99
        tuning.travelCollapse = -5
        tuning.edgeCushion = 99
        XCTAssertEqual(tuning.pathWindowSeconds, TuningSettings.pathWindowSecondsRange.upperBound)
        XCTAssertEqual(tuning.travelCollapse, TuningSettings.travelCollapseRange.lowerBound)
        XCTAssertEqual(tuning.edgeCushion, TuningSettings.edgeCushionRange.upperBound)
    }

    func test_tuningSettings_decodeMissingFields_usesDefaults() throws {
        let decoded = try JSONDecoder().decode(TuningSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .default)

        let partial = try JSONDecoder().decode(
            TuningSettings.self,
            from: Data(#"{"cameraTau": 0.6, "smoothingScope": "zoomsOnly"}"#.utf8)
        )
        XCTAssertEqual(partial.cameraTau, 0.6, accuracy: 1e-9)
        XCTAssertEqual(partial.smoothingScope, .zoomsOnly)
        XCTAssertEqual(partial.settle, TuningSettings.default.settle)
        XCTAssertEqual(partial.fastMotionSensitivity, TuningSettings.default.fastMotionSensitivity)
        XCTAssertEqual(partial.edgeCushion, TuningSettings.default.edgeCushion)
    }

    func test_migrator_v5ToV6_dropsZoomFollowStyleKey() throws {
        let v5: [String: Any] = [
            "schemaVersion": 5,
            "bundleVersion": 1,
            "id": "p5",
            "name": "v5 doc",
            "createdAt": "2026-06-01T00:00:00Z",
            "modifiedAt": "2026-06-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:],
            "zoomFollowStyle": ["float": 0.65, "speed": 0.35, "softness": 0.60]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v5)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)
        XCTAssertNil(migrated["zoomFollowStyle"])

        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(project.tuning, .default)
    }

    func test_migrator_v6ToV7_replacesExactOldDefaultTuningWithNewDefault() throws {
        let v6: [String: Any] = [
            "schemaVersion": 6,
            "bundleVersion": 1,
            "id": "p6-default",
            "name": "v6 default tuning",
            "createdAt": "2026-06-01T00:00:00Z",
            "modifiedAt": "2026-06-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:],
            "tuning": [
                "cameraTau": 0.35,
                "settle": 0.25,
                "deadzoneFraction": 0.35,
                "maxPanSpeed": 0.9,
                "lookaheadSeconds": 0.04,
                "pathWindowSeconds": 0.35,
                "travelCollapse": 0.7,
                "clickSnapWindow": 0.15,
                "smoothingScope": "fullRecording",
                "shutterAngle": 180,
                "blurStrength": 1.0,
                "cursorBlur": 0.6,
                "transitionSoftness": 0.5
            ]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v6)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)

        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(project.tuning, .default)
    }

    func test_migrator_v6ToV7_preservesCustomizedTuningAndAddsNewFields() throws {
        let v6: [String: Any] = [
            "schemaVersion": 6,
            "bundleVersion": 1,
            "id": "p6-custom",
            "name": "v6 custom tuning",
            "createdAt": "2026-06-01T00:00:00Z",
            "modifiedAt": "2026-06-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:],
            "tuning": [
                "cameraTau": 0.7,
                "settle": 0.25,
                "deadzoneFraction": 0.35,
                "maxPanSpeed": 0.9,
                "lookaheadSeconds": 0.04,
                "pathWindowSeconds": 0.35,
                "travelCollapse": 0.7,
                "clickSnapWindow": 0.15,
                "smoothingScope": "fullRecording",
                "shutterAngle": 180,
                "blurStrength": 1.0,
                "cursorBlur": 0.6,
                "transitionSoftness": 0.5
            ]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v6)
        let tuning = try XCTUnwrap(migrated["tuning"] as? [String: Any])
        XCTAssertEqual(tuning["cameraTau"] as? Double, 0.7)
        XCTAssertEqual(tuning["fastMotionSensitivity"] as? Double, TuningSettings.default.fastMotionSensitivity)
        XCTAssertEqual(tuning["edgeCushion"] as? Double, TuningSettings.default.edgeCushion)
    }

    func test_decodeLegacySourceSegment_missingExtras_usesEmptyExtras() throws {
        let json = """
        {
          "assetID": "asset-screen",
          "timelineRange": {
            "start": { "value": 0, "timescale": 600 },
            "duration": { "value": 6000, "timescale": 600 }
          }
        }
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(SourceSegment.self, from: json)

        XCTAssertEqual(segment.assetID.rawValue, "asset-screen")
        XCTAssertEqual(segment.extras, [:])
    }

    func test_decodeLegacyCursorSettings_missingDefaultedFields_usesDefaults() throws {
        let json = """
        {
          "isEnabled": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(CursorSettings.self, from: json)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.scale, CursorSettings.defaultScale)
        XCTAssertEqual(settings.extras, [:])
    }

    func test_cursorSettingsTuningExtras_clampPersistAndClearDefaults() {
        var settings = CursorSettings.default
        XCTAssertEqual(settings.zoomScaleBoostPerZoomUnit, CursorSettings.defaultZoomScaleBoostPerZoomUnit)
        XCTAssertEqual(settings.velocityScaleBoost, CursorSettings.defaultVelocityScaleBoost)
        XCTAssertEqual(settings.blurShutterMax, CursorSettings.defaultBlurShutterMax)

        settings.zoomScaleBoostPerZoomUnit = 1.1
        settings.velocityScaleBoost = 0.2
        settings.velocityScaleLow = 0.3
        settings.velocityScaleHigh = 1.6
        settings.blurSpeedLow = 0.45
        settings.blurSpeedHigh = 3.2
        settings.blurShutterMin = 1.0 / 100.0
        settings.blurShutterMax = 1.0 / 25.0
        settings.blurMaxUV = 1.4

        XCTAssertEqual(settings.extras["zoomScaleBoostPerZoomUnit"], .double(1.1))
        XCTAssertEqual(settings.extras["velocityScaleBoost"], .double(0.2))
        XCTAssertEqual(settings.extras["velocityScaleLow"], .double(0.3))
        XCTAssertEqual(settings.extras["velocityScaleHigh"], .double(1.6))
        XCTAssertEqual(settings.extras["blurSpeedLow"], .double(0.45))
        XCTAssertEqual(settings.extras["blurSpeedHigh"], .double(3.2))
        XCTAssertEqual(settings.extras["blurShutterMin"], .double(1.0 / 100.0))
        XCTAssertEqual(settings.extras["blurShutterMax"], .double(1.0 / 25.0))
        XCTAssertEqual(settings.extras["blurMaxUV"], .double(1.4))

        settings.blurMaxUV = 99
        XCTAssertEqual(settings.blurMaxUV, CursorSettings.blurMaxUVRange.upperBound)
        settings.blurMaxUV = CursorSettings.defaultBlurMaxUV
        XCTAssertNil(settings.extras["blurMaxUV"])
    }

    // MARK: - Migrator chain

    func test_migratorChain_advancesV1ToCurrent_withoutDataLoss() throws {
        let v1Document: [String: Any] = [
            "schemaVersion": 1,
            "bundleVersion": 1,
            "id": ["rawValue": "p1"],
            "name": "Migration test",
            "createdAt": "2026-05-01T00:00:00Z",
            "modifiedAt": "2026-05-01T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:]
        ]
        let migrated = try MigrationRegistry.standard.migrate(v1Document)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)
        XCTAssertEqual(migrated["name"] as? String, "Migration test")
    }

    func test_migrator_rejectsFutureSchemaVersions() {
        let futureDocument: [String: Any] = [
            "schemaVersion": currentSchemaVersion + 5
        ]
        XCTAssertThrowsError(try MigrationRegistry.standard.migrate(futureDocument)) { error in
            guard case MigrationError.schemaVersionTooNew = error else {
                return XCTFail("expected .schemaVersionTooNew, got \(error)")
            }
        }
    }

    func test_migrator_rejectsMissingSchemaVersion() {
        XCTAssertThrowsError(try MigrationRegistry.standard.migrate([:])) { error in
            guard case MigrationError.missingSchemaVersion = error else {
                return XCTFail("expected .missingSchemaVersion, got \(error)")
            }
        }
    }

    // MARK: - Forward-compat extras preservation

    func test_extras_unknownFieldsRoundTripThroughJSONValue() throws {
        // A future Pixelbay binary writes a track with a `colorLabel` extras key.
        // Today's binary does not know about colorLabel, but must NOT drop it
        // when re-saving. The JSONValue-based extras dict is how this works.
        let json = """
        {
          "id": "t-1",
          "kind": "screen",
          "name": "Screen",
          "clips": [],
          "muted": false,
          "hidden": false,
          "extras": {
            "colorLabel": "magenta",
            "futureNumber": 42,
            "nested": { "a": [1, 2, 3] }
          }
        }
        """.data(using: .utf8)!

        let track = try JSONDecoder().decode(Track.self, from: json)
        XCTAssertEqual(track.extras["colorLabel"], .string("magenta"))
        XCTAssertEqual(track.extras["futureNumber"], .int(42))

        let reEncoded = try JSONEncoder().encode(track)
        let reDecoded = try JSONDecoder().decode(Track.self, from: reEncoded)
        XCTAssertEqual(reDecoded.extras, track.extras,
                       "extras must round-trip identically")
    }

    // MARK: - Non-destructive trim invariant

    func test_nonDestructiveTrim_canExpandBackOut() {
        // A clip slices into a 30-second media file at 5..15s. The user later
        // drags the clip's left edge back to 3s, which must be possible because
        // sourceRange is independent of timelineRange, so the underlying file
        // still has those frames available.
        let asset = MediaAsset(
            kind: .display,
            relativePath: "media/screen-001.mov",
            nativeDuration: .seconds(30)
        )
        var clip = Clip(
            assetID: asset.id,
            sourceRange: TimeRange(start: .seconds(5), duration: .seconds(10)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(10))
        )

        // Expand the in-point back to 3s, recovering 2s of previously trimmed material.
        let recoveredSourceStart = RationalTime.seconds(3)
        let recoveredAmount = clip.sourceRange.start.seconds - recoveredSourceStart.seconds
        clip.sourceRange = TimeRange(
            start: recoveredSourceStart,
            duration: .seconds(clip.sourceRange.duration.seconds + recoveredAmount)
        )
        clip.timelineRange = TimeRange(
            start: clip.timelineRange.start,
            duration: .seconds(clip.timelineRange.duration.seconds + recoveredAmount)
        )

        XCTAssertEqual(clip.sourceRange.start.seconds, 3.0, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceRange.duration.seconds, 12.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(clip.sourceRange.end.seconds, asset.nativeDuration.seconds,
                                 "expanded source range must fit within the underlying media")
    }

    // MARK: - TimeRange.overlaps (half-open)

    func test_timeRange_overlaps_isFalseForAdjacentRanges() {
        let a = TimeRange(start: .seconds(1), duration: .seconds(2))     // [1, 3)
        let b = TimeRange(start: .seconds(3), duration: .seconds(2))     // [3, 5)
        XCTAssertFalse(a.overlaps(b))
        XCTAssertFalse(b.overlaps(a))
    }

    func test_timeRange_overlaps_isTrueForPartialOverlap() {
        let a = TimeRange(start: .seconds(1), duration: .seconds(3))     // [1, 4)
        let b = TimeRange(start: .seconds(2), duration: .seconds(3))     // [2, 5)
        XCTAssertTrue(a.overlaps(b))
        XCTAssertTrue(b.overlaps(a))
    }

    func test_timeRange_overlaps_isTrueForContainment() {
        let outer = TimeRange(start: .seconds(0), duration: .seconds(10))   // [0, 10)
        let inner = TimeRange(start: .seconds(3), duration: .seconds(2))    // [3, 5)
        XCTAssertTrue(outer.overlaps(inner))
        XCTAssertTrue(inner.overlaps(outer))
    }

    func test_timeRange_overlaps_isFalseForDisjointRanges() {
        let a = TimeRange(start: .seconds(0), duration: .seconds(2))     // [0, 2)
        let b = TimeRange(start: .seconds(5), duration: .seconds(2))     // [5, 7)
        XCTAssertFalse(a.overlaps(b))
        XCTAssertFalse(b.overlaps(a))
    }

    // MARK: - Project+TimelineCollapse (Branch B, 2026-05-27)

    func test_timelineLaneCollapse_extras_roundTripThroughCodable() throws {
        var project = Project(name: "Collapse round-trip")
        project.timelineLaneCollapse = [.video: false, .audio: true]
        project.timelineLaneCollapseDefault = false

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoded = try decoder.decode(Project.self, from: data)

        XCTAssertEqual(decoded.timelineLaneCollapse[.video], false)
        XCTAssertEqual(decoded.timelineLaneCollapse[.audio], true)
        XCTAssertEqual(decoded.timelineLaneCollapseDefault, false)
    }

    func test_timelineLaneCollapse_freshProject_defaultsToCollapsed() {
        let project = Project(name: "Fresh")
        // Smart-default seed: both groups read as collapsed when no
        // entry has been written yet.
        XCTAssertTrue(project.isLaneCollapsed(.video))
        XCTAssertTrue(project.isLaneCollapsed(.audio))
        XCTAssertTrue(project.timelineLaneCollapseDefault)
        XCTAssertTrue(project.timelineLaneCollapse.isEmpty,
                      "extras key absent until first write")
    }

    func test_timelineLaneCollapse_perLaneOverridesDefault() {
        var project = Project(name: "Override")
        project.timelineLaneCollapseDefault = true
        project.timelineLaneCollapse = [.video: false]

        XCTAssertFalse(project.isLaneCollapsed(.video),
                       "per-lane override wins over default")
        XCTAssertTrue(project.isLaneCollapsed(.audio),
                      "untouched lane still uses default")
    }

    func test_timelineLaneCollapse_emptySet_clearsExtrasKey() {
        var project = Project(name: "Clear")
        project.timelineLaneCollapse = [.video: false]
        XCTAssertNotNil(project.extras["timelineLaneCollapse"])
        project.timelineLaneCollapse = [:]
        XCTAssertNil(project.extras["timelineLaneCollapse"],
                     "writing empty map should remove the extras entry")
    }

    func test_trackKind_laneGroup_mapping() {
        XCTAssertEqual(TrackKind.screen.laneGroup, .video)
        XCTAssertEqual(TrackKind.webcam.laneGroup, .video)
        XCTAssertEqual(TrackKind.overlay.laneGroup, .video)
        XCTAssertEqual(TrackKind.microphone.laneGroup, .audio)
        XCTAssertEqual(TrackKind.systemAudio.laneGroup, .audio)
        XCTAssertEqual(TrackKind.voiceover.laneGroup, .audio)
        XCTAssertNil(TrackKind.effects.laneGroup,
                     "effects track stays standalone, not part of a group")
    }
}
