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

    func test_zoomFollowDefaults_areSmoothAndAdjustable() {
        var kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2))
        )
        XCTAssertEqual(kf.zoomFollowSafeZoneFraction, 0.38, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowMotionBlur, 0.30, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowMaxAnchorSpeed, 1.30, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowLookaheadSeconds, 0.072, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowTauRelaxed, 0.190, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowTauTight, 0.060, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowAnticipationHalfWindow, 0.152, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurShutterSeconds, 1.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurMaxUV, 0.006, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurThresholdSpeed, 1.32, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurFullSpeed, 0.80, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomCenterHandoffSeconds, 0.343, accuracy: 1e-9)

        kf.zoomFollowSafeZoneFraction = 0.42
        kf.zoomFollowMotionBlur = 1.8
        kf.zoomFollowMaxAnchorSpeed = 1.4
        kf.zoomFollowLookaheadSeconds = 0.08
        kf.zoomFollowTauRelaxed = 0.12
        kf.zoomFollowTauTight = 0.05
        kf.zoomFollowAnticipationHalfWindow = 0.3
        kf.zoomPanBlurShutterSeconds = 1.0 / 40.0
        kf.zoomPanBlurMaxUV = 0.04
        kf.zoomPanBlurThresholdSpeed = 0.2
        kf.zoomPanBlurFullSpeed = 0.9
        kf.zoomCenterHandoffSeconds = 0.24
        XCTAssertEqual(kf.zoomFollowSafeZoneFraction, 0.42, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowMotionBlur, 1.8, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowMaxAnchorSpeed, 1.4, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowLookaheadSeconds, 0.08, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowTauRelaxed, 0.12, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowTauTight, 0.05, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomFollowAnticipationHalfWindow, 0.3, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurShutterSeconds, 1.0 / 40.0, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurMaxUV, 0.04, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurThresholdSpeed, 0.2, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomPanBlurFullSpeed, 0.9, accuracy: 1e-9)
        XCTAssertEqual(kf.zoomCenterHandoffSeconds, 0.24, accuracy: 1e-9)
        XCTAssertEqual(kf.extras["zoomFollowSafeZoneFraction"], .double(0.42))
        XCTAssertEqual(kf.extras["zoomFollowMotionBlur"], .double(1.8))
        XCTAssertEqual(kf.extras["zoomFollowMaxAnchorSpeed"], .double(1.4))
        XCTAssertEqual(kf.extras["zoomFollowLookaheadSeconds"], .double(0.08))
        XCTAssertEqual(kf.extras["zoomFollowTauRelaxed"], .double(0.12))
        XCTAssertEqual(kf.extras["zoomFollowTauTight"], .double(0.05))
        XCTAssertEqual(kf.extras["zoomFollowAnticipationHalfWindow"], .double(0.3))
        XCTAssertEqual(kf.extras["zoomPanBlurShutterSeconds"], .double(1.0 / 40.0))
        XCTAssertEqual(kf.extras["zoomPanBlurMaxUV"], .double(0.04))
        XCTAssertEqual(kf.extras["zoomPanBlurThresholdSpeed"], .double(0.2))
        XCTAssertEqual(kf.extras["zoomPanBlurFullSpeed"], .double(0.9))
        XCTAssertEqual(kf.extras["zoomCenterHandoffSeconds"], .double(0.24))
    }

    func test_zoomFollowSettings_clampAndClearAtDefaults() {
        var kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(start: .seconds(0), duration: .seconds(2))
        )
        kf.zoomFollowSafeZoneFraction = 99
        kf.zoomFollowMotionBlur = -5
        kf.zoomFollowMaxAnchorSpeed = 99
        kf.zoomFollowLookaheadSeconds = -1
        kf.zoomFollowTauRelaxed = 99
        kf.zoomFollowTauTight = -1
        kf.zoomFollowAnticipationHalfWindow = 99
        kf.zoomPanBlurShutterSeconds = 99
        kf.zoomPanBlurMaxUV = 99
        kf.zoomPanBlurThresholdSpeed = -1
        kf.zoomPanBlurFullSpeed = 99
        kf.zoomCenterHandoffSeconds = 99
        XCTAssertEqual(kf.zoomFollowSafeZoneFraction, EffectKeyframe.zoomFollowSafeZoneRange.upperBound)
        XCTAssertEqual(kf.zoomFollowMotionBlur, EffectKeyframe.zoomFollowMotionBlurRange.lowerBound)
        XCTAssertEqual(kf.zoomFollowMaxAnchorSpeed, EffectKeyframe.zoomFollowMaxAnchorSpeedRange.upperBound)
        XCTAssertEqual(kf.zoomFollowLookaheadSeconds, EffectKeyframe.zoomFollowLookaheadSecondsRange.lowerBound)
        XCTAssertEqual(kf.zoomFollowTauRelaxed, EffectKeyframe.zoomFollowTauRelaxedRange.upperBound)
        XCTAssertEqual(kf.zoomFollowTauTight, EffectKeyframe.zoomFollowTauTightRange.lowerBound)
        XCTAssertEqual(kf.zoomFollowAnticipationHalfWindow, EffectKeyframe.zoomFollowAnticipationHalfWindowRange.upperBound)
        XCTAssertEqual(kf.zoomPanBlurShutterSeconds, EffectKeyframe.zoomPanBlurShutterSecondsRange.upperBound)
        XCTAssertEqual(kf.zoomPanBlurMaxUV, EffectKeyframe.zoomPanBlurMaxUVRange.upperBound)
        XCTAssertEqual(kf.zoomPanBlurThresholdSpeed, EffectKeyframe.zoomPanBlurThresholdSpeedRange.lowerBound)
        XCTAssertEqual(kf.zoomPanBlurFullSpeed, EffectKeyframe.zoomPanBlurFullSpeedRange.upperBound)
        XCTAssertEqual(kf.zoomCenterHandoffSeconds, EffectKeyframe.zoomCenterHandoffSecondsRange.upperBound)

        kf.zoomFollowSafeZoneFraction = EffectKeyframe.defaultZoomFollowSafeZoneFraction
        kf.zoomFollowMotionBlur = EffectKeyframe.defaultZoomFollowMotionBlur
        kf.zoomFollowMaxAnchorSpeed = EffectKeyframe.defaultZoomFollowMaxAnchorSpeed
        kf.zoomFollowLookaheadSeconds = EffectKeyframe.defaultZoomFollowLookaheadSeconds
        kf.zoomFollowTauRelaxed = EffectKeyframe.defaultZoomFollowTauRelaxed
        kf.zoomFollowTauTight = EffectKeyframe.defaultZoomFollowTauTight
        kf.zoomFollowAnticipationHalfWindow = EffectKeyframe.defaultZoomFollowAnticipationHalfWindow
        kf.zoomPanBlurShutterSeconds = EffectKeyframe.defaultZoomPanBlurShutterSeconds
        kf.zoomPanBlurMaxUV = EffectKeyframe.defaultZoomPanBlurMaxUV
        kf.zoomPanBlurThresholdSpeed = EffectKeyframe.defaultZoomPanBlurThresholdSpeed
        kf.zoomPanBlurFullSpeed = EffectKeyframe.defaultZoomPanBlurFullSpeed
        kf.zoomCenterHandoffSeconds = EffectKeyframe.defaultZoomCenterHandoffSeconds
        XCTAssertNil(kf.extras["zoomFollowSafeZoneFraction"])
        XCTAssertNil(kf.extras["zoomFollowMotionBlur"])
        XCTAssertNil(kf.extras["zoomFollowMaxAnchorSpeed"])
        XCTAssertNil(kf.extras["zoomFollowLookaheadSeconds"])
        XCTAssertNil(kf.extras["zoomFollowTauRelaxed"])
        XCTAssertNil(kf.extras["zoomFollowTauTight"])
        XCTAssertNil(kf.extras["zoomFollowAnticipationHalfWindow"])
        XCTAssertNil(kf.extras["zoomPanBlurShutterSeconds"])
        XCTAssertNil(kf.extras["zoomPanBlurMaxUV"])
        XCTAssertNil(kf.extras["zoomPanBlurThresholdSpeed"])
        XCTAssertNil(kf.extras["zoomPanBlurFullSpeed"])
        XCTAssertNil(kf.extras["zoomCenterHandoffSeconds"])
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
