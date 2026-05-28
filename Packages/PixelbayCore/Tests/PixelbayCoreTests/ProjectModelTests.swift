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
