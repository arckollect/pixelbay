import XCTest
@testable import PixelbayCore

final class EffectKeyframeTests: XCTestCase {

    // MARK: - Codable

    func test_zoomKeyframe_roundTripsThroughCodable() throws {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2)),
            zoomFactor: 1.8,
            centerX: 0.3,
            centerY: 0.7,
            easeIn: .seconds(0.25),
            easeOut: .seconds(0.4)
        )
        let data = try JSONEncoder().encode(kf)
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
        XCTAssertEqual(decoded, kf)
    }

    func test_talkingHeadKeyframe_roundTripsThroughCodable() throws {
        let kf = EffectKeyframe(
            kind: .talkingHeadSwap,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(3))
        )
        let data = try JSONEncoder().encode(kf)
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
        XCTAssertEqual(decoded, kf)
    }

    func test_zoomKeyframe_withTrajectory_roundTripsThroughCodable() throws {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(2.5)),
            zoomFactor: 1.6,
            centerX: 0.5,
            centerY: 0.5,
            trajectory: [
                ZoomTrajectorySample(t: 0.0, x: 0.50, y: 0.50),
                ZoomTrajectorySample(t: 0.5, x: 0.55, y: 0.48),
                ZoomTrajectorySample(t: 1.0, x: 0.62, y: 0.45),
                ZoomTrajectorySample(t: 2.0, x: 0.70, y: 0.40)
            ]
        )
        let data = try JSONEncoder().encode(kf)
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
        XCTAssertEqual(decoded, kf)
        XCTAssertEqual(decoded.trajectory?.count, 4)
    }

    func test_zoomKeyframe_withoutTrajectory_decodesNilTrajectory() throws {
        // Synthesised JSON shaped like a pre-2026-05-13 keyframe — `trajectory`
        // key absent. Must decode with `trajectory == nil` (optional field via
        // synthesised Codable).
        let json = """
        {
            "id": "kf-1",
            "kind": "zoom",
            "timelineRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}},
            "zoomFactor": 1.5,
            "centerX": 0.5,
            "centerY": 0.5,
            "easeIn": {"value": 120, "timescale": 600},
            "easeOut": {"value": 120, "timescale": 600},
            "extras": {}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
        XCTAssertNil(decoded.trajectory)
    }

    func test_zoomTrajectorySample_codable_roundTrip() throws {
        let sample = ZoomTrajectorySample(t: 1.5, x: 0.25, y: 0.75)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ZoomTrajectorySample.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_keyframe_originDefaultsToAutoOnDecodeWhenMissing() throws {
        // Legacy fixture without the `origin` field — pre-slice-#11.d
        // projects must still decode (Optional + decodeIfPresent → .auto).
        let json = """
        {
            "id": "kf-1",
            "kind": "zoom",
            "timelineRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}},
            "zoomFactor": 1.5,
            "centerX": 0.5,
            "centerY": 0.5,
            "easeIn": {"value": 120, "timescale": 600},
            "easeOut": {"value": 120, "timescale": 600},
            "extras": {}
        }
        """
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.origin, .auto)
    }

    func test_keyframe_extrasDefaultsToEmptyOnDecodeWhenMissing() throws {
        let json = """
        {
            "id": "kf-1",
            "kind": "zoom",
            "timelineRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}},
            "zoomFactor": 1.5,
            "centerX": 0.5,
            "centerY": 0.5,
            "easeIn": {"value": 120, "timescale": 600},
            "easeOut": {"value": 120, "timescale": 600}
        }
        """
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extras, [:])
    }

    func test_keyframe_manualHotkeyOrigin_roundTripsThroughCodable() throws {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            origin: .manualHotkey
        )
        let data = try JSONEncoder().encode(kf)
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
        XCTAssertEqual(decoded.origin, .manualHotkey)
    }

    func test_keyframe_anchorMode_roundTripsThroughCodable() throws {
        for mode in ZoomAnchorMode.allCases {
            let kf = EffectKeyframe(
                kind: .zoom,
                timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
                anchorMode: mode
            )
            let data = try JSONEncoder().encode(kf)
            let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: data)
            XCTAssertEqual(decoded.anchorMode, mode, "anchorMode \(mode) must survive JSON round-trip")
        }
    }

    func test_keyframe_anchorModeDefaultsToFollowCursorOnDecodeWhenMissing() throws {
        // Legacy fixture without the `anchorMode` field — pre-2026-05-15
        // projects must decode with .followCursor so existing zoom keyframes
        // keep their cursor-tracking behaviour.
        let json = """
        {
            "id": "kf-1",
            "kind": "zoom",
            "timelineRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}},
            "zoomFactor": 1.5,
            "centerX": 0.5,
            "centerY": 0.5,
            "easeIn": {"value": 120, "timescale": 600},
            "easeOut": {"value": 120, "timescale": 600},
            "origin": "auto",
            "extras": {}
        }
        """
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.anchorMode, .followCursor)
    }

    func test_project_defaultsToEmptyEffects() {
        let project = Project(name: "default")
        XCTAssertTrue(project.effects.isEmpty)
    }

    func test_project_carriesEffectsThroughCodable() throws {
        let kf = EffectKeyframe(kind: .zoom, timelineRange: TimeRange(start: .seconds(1), duration: .seconds(2)))
        let project = Project(name: "with effects", effects: [kf])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(decoded.effects.count, 1)
        XCTAssertEqual(decoded.effects[0].id, kf.id)
    }

    // MARK: - strength(at:)

    func test_zoomEaseDefaults_areSharedSmoothCadence() {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2))
        )

        XCTAssertEqual(EffectKeyframe.defaultZoomEaseIn.seconds, 0.55, accuracy: 1e-9)
        XCTAssertEqual(EffectKeyframe.defaultZoomEaseOut.seconds, 0.55, accuracy: 1e-9)
        XCTAssertEqual(kf.easeIn, EffectKeyframe.defaultZoomEaseIn)
        XCTAssertEqual(kf.easeOut, EffectKeyframe.defaultZoomEaseOut)
    }

    func test_strength_transitionSoftness_stretchesTheTails() {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(1.0),
            easeOut: .seconds(0)
        )
        // Endpoints and the hold are unchanged at any softness.
        XCTAssertEqual(kf.strength(at: 0, transitionSoftness: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(kf.strength(at: 1.5, transitionSoftness: 1), 1, accuracy: 1e-12)
        // Early in the ease the softened curve sits BELOW the quintic
        // (longer tail near 0); late in the ease it sits ABOVE (longer
        // tail near 1). Softness 0 is bit-identical to the historic ramp.
        XCTAssertLessThan(
            kf.strength(at: 0.25, transitionSoftness: 1),
            kf.strength(at: 0.25, transitionSoftness: 0),
            "softness must linger near 0 early in the ease"
        )
        XCTAssertGreaterThan(
            kf.strength(at: 0.75, transitionSoftness: 1),
            kf.strength(at: 0.75, transitionSoftness: 0),
            "softness must approach 1 sooner-but-gentler late in the ease"
        )
        XCTAssertEqual(
            kf.strength(at: 0.4, transitionSoftness: 0),
            kf.strength(at: 0.4),
            accuracy: 1e-12
        )
    }

    func test_retiredZoomFollowExtras_areTolerated() throws {
        // Pre-v6 projects may carry the retired camera-spring keys in
        // `extras` (zoomFollowTauRelaxed etc.). They must decode cleanly
        // and survive a round-trip as inert data.
        let json = """
        {
            "id": "kf-stale",
            "kind": "zoom",
            "timelineRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 1200, "timescale": 600}},
            "zoomFactor": 1.5,
            "centerX": 0.5,
            "centerY": 0.5,
            "easeIn": {"value": 120, "timescale": 600},
            "easeOut": {"value": 120, "timescale": 600},
            "extras": {
                "zoomFollowSafeZoneFraction": 0.42,
                "zoomFollowTauRelaxed": 0.12,
                "zoomFollowRebound": 0.72,
                "zoomFollowPullAcceleration": 4.4
            }
        }
        """
        let decoded = try JSONDecoder().decode(EffectKeyframe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extras["zoomFollowTauRelaxed"], .double(0.12))
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(EffectKeyframe.self, from: reencoded)
        XCTAssertEqual(roundTripped.extras["zoomFollowSafeZoneFraction"], .double(0.42))
    }

    func test_strength_returnsZeroOutsideRange() {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(2)),
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        XCTAssertEqual(kf.strength(at: 1.99), 0)
        XCTAssertEqual(kf.strength(at: 4.0), 0, accuracy: 1e-9)
    }

    func test_strength_peaksDuringHold() {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(2), duration: .seconds(2)),
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        // Hold window is 2.5 → 3.5 (1s after easeIn finishes, 1s before easeOut starts).
        XCTAssertEqual(kf.strength(at: 2.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(kf.strength(at: 3.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(kf.strength(at: 3.5 - 0.01), 1.0, accuracy: 0.01)
    }

    func test_strength_easesInAndOut_monotonically() {
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(0.5),
            easeOut: .seconds(0.5)
        )
        // ease-in samples: 0.0 → 0.5 should be monotonically increasing toward 1.
        let inSamples = stride(from: 0.05, to: 0.5, by: 0.05).map { kf.strength(at: $0) }
        for i in 1..<inSamples.count {
            XCTAssertGreaterThanOrEqual(inSamples[i], inSamples[i-1] - 1e-9, "ease-in not monotonic")
        }
        // ease-out samples: 1.5 → 2.0 should be monotonically decreasing toward 0.
        let outSamples = stride(from: 1.5, to: 1.99, by: 0.05).map { kf.strength(at: $0) }
        for i in 1..<outSamples.count {
            XCTAssertLessThanOrEqual(outSamples[i], outSamples[i-1] + 1e-9, "ease-out not monotonic")
        }
    }

    func test_smoothstep_isQuinticShape_softerThanCubicAtBoundaries() {
        // Quintic smoothstep 6x⁵-15x⁴+10x³ vs cubic 3x²-2x³. By construction
        // the quintic form ramps slower near the boundaries (its acceleration
        // is zero at 0 and 1, not just its velocity). Cubic at x=0.25 is
        // 0.15625; quintic is 0.103515625. Asserting the exact value pins
        // the curve so a future revert to cubic wouldn't pass silently.
        XCTAssertEqual(EffectKeyframe.smoothstep(0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(EffectKeyframe.smoothstep(0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EffectKeyframe.smoothstep(1.0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(EffectKeyframe.smoothstep(0.25), 0.103515625, accuracy: 1e-12)
        XCTAssertEqual(EffectKeyframe.smoothstep(0.75), 0.896484375, accuracy: 1e-12)
    }

    func test_strength_handlesOverlongEaseWindowsViaProportionalShrink() {
        // easeIn + easeOut = 4s but range is only 2s — should still produce a
        // valid 0..1 strength curve, never crashing or going negative.
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2)),
            easeIn: .seconds(3),
            easeOut: .seconds(1)
        )
        for t in stride(from: 0.0, to: 2.0, by: 0.1) {
            let s = kf.strength(at: t)
            XCTAssertGreaterThanOrEqual(s, 0)
            XCTAssertLessThanOrEqual(s, 1 + 1e-9)
        }
    }

    // MARK: - Migrator v2 → v3

    func test_migrator_addsEffectsArrayToV2Document() throws {
        let v2: [String: Any] = [
            "schemaVersion": 2,
            "bundleVersion": 1,
            "id": "p2",
            "name": "v2 doc",
            "createdAt": "2026-05-12T00:00:00Z",
            "modifiedAt": "2026-05-12T00:00:00Z",
            "assets": [],
            "tracks": [],
            "sourceSegments": [],
            "extras": [:],
            "layout": Migrator1To2.defaultLayoutJSON()
        ]
        let migrated = try MigrationRegistry.standard.migrate(v2)
        // `MigrationRegistry.standard` chains all registered migrators
        // (v2→v3→v4 here) — the test originally asserted == 3, but bumping
        // currentSchemaVersion past 3 means the chain runs further. Assert
        // against `currentSchemaVersion` so future bumps don't re-break
        // this test.
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)
        let effects = migrated["effects"] as? [Any]
        XCTAssertNotNil(effects)
        XCTAssertEqual(effects?.count, 0)
    }

    func test_migrator_v1ToV3_chainsCleanly() throws {
        // Whole chain: v1 → v2 (adds layout) → v3 (adds effects) → v4
        // (adds cursorSettings). Asserts the chain advances all the way
        // to `currentSchemaVersion` and that fields stamped along the way
        // are present.
        let v1: [String: Any] = [
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
        let migrated = try MigrationRegistry.standard.migrate(v1)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, currentSchemaVersion)
        XCTAssertNotNil(migrated["layout"])
        XCTAssertNotNil(migrated["effects"])
        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(project.schemaVersion, currentSchemaVersion)
        XCTAssertEqual(project.layout, .phase1Default)
        XCTAssertTrue(project.effects.isEmpty)
    }
}
