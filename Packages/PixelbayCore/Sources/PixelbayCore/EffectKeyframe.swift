import Foundation

// Phase 3b: time-ranged visual effects applied on top of the base
// `LayoutPreset`. Each keyframe is independent; non-overlapping zoom
// keyframes layer additively (multiple consecutive auto-zooms from a
// click sidecar are each their own segment).
//
// Compositor evaluation: at render time, given the playhead time T, the
// compositor walks `Project.effects`, picks every keyframe with T inside
// `timelineRange` (ease-in / ease-out windows count too), and modifies the
// resolved layout for that frame:
//   - .zoom: scale + translate the screen layer's destination rect so the
//     specified normalised center fills the configured zoom factor.
//   - .talkingHeadSwap: swap the screen + webcam layer slots so the cam
//     fills the output (the screen is hidden, or shrunk to the cam slot).
//
// During the ease-in / ease-out windows the effect strength interpolates
// from 0 → 1 (cubic-ease for smoothness). Outside the keyframe's window
// the effect contributes 0 and is skipped.

public struct EffectKeyframeID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> EffectKeyframeID {
        EffectKeyframeID(rawValue: UUID().uuidString)
    }
}

public enum EffectKind: String, Codable, Sendable, CaseIterable {
    case zoom
    case talkingHeadSwap
}

/// Where the keyframe came from. Drives the timeline's badge color so the
/// user can tell at a glance which keyframes were AI-guessed (auto) vs
/// intentional (manualHotkey). Defaults to `.auto` on decode when the field
/// is missing (legacy projects from before slice #11.d).
public enum ZoomOrigin: String, Codable, Sendable, CaseIterable {
    case auto
    case manualHotkey
}

/// How the per-frame zoom centre is sourced.
///
/// `.followCursor` (the historical default): the per-frame centre comes from
/// `trajectory` when one is present (or is filled in at composition build
/// time from the master cursor trajectory if absent); falls back to the
/// static `(centerX, centerY)` only when no trajectory exists.
///
/// `.pinned`: the centre is **always** the static `(centerX, centerY)`, even
/// if `trajectory` is non-nil. Critically, `PreviewComposition.applyCursorTrajectory`
/// also leaves pinned keyframes alone — it would otherwise re-slice the
/// master cursor trajectory onto the keyframe at every composition build
/// (including playback rebuilds) and silently re-enable cursor-tracking on
/// keyframes the user explicitly wanted region-locked. Used by gesture-
/// sourced marks (shake / circle) where the gesture's purpose is "zoom on
/// this region, then stay put."
///
/// Decoded as `.followCursor` when missing (legacy projects from before
/// 2026-05-15).
public enum ZoomAnchorMode: String, Codable, Sendable, CaseIterable {
    case followCursor
    case pinned
}

/// One waypoint on a zoom keyframe's cursor-tracking trajectory. `t` is
/// keyframe-local seconds (t=0 at `timelineRange.start`); `x` / `y` are
/// normalised to the screen layer's local space, same convention as
/// `EffectKeyframe.centerX` / `centerY`.
///
/// Attached via `EffectKeyframe.trajectory` when the keyframe was generated
/// from a click sidecar that also carried mouse-move samples
/// (Phase 3b #7 slice 1/3 — `ClicksSidecar.moves`). Per-frame interpolation
/// is slice 3/3 and lives in `PixelbayCompositor.EffectEvaluator`.
public struct ZoomTrajectorySample: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

/// Single visual effect anchored to a timeline range.
///
/// `easeIn` + `easeOut` are durations *inside* `timelineRange` — i.e. the
/// effect ramps from 0 → 1 over the first `easeIn`, holds at 1 for the
/// middle, then ramps 1 → 0 over the final `easeOut`. Both default to
/// 200ms (a snappy but not jarring snap). Total `timelineRange.duration`
/// must be ≥ `easeIn + easeOut`.
///
/// For `.zoom`: `zoomFactor` ≥ 1; `centerX` / `centerY` ∈ [0, 1] in the
/// screen layer's local space (0,0 = top-left, 1,1 = bottom-right).
///
/// For `.talkingHeadSwap`: zoom params are ignored; the layout swaps so
/// the webcam fills the screen slot and (depending on `swapStyle`) either
/// hides the original screen or shrinks it to the webcam slot.
public struct EffectKeyframe: Codable, Sendable, Identifiable, Equatable {
    public let id: EffectKeyframeID
    public var kind: EffectKind
    public var timelineRange: TimeRange
    public var zoomFactor: Double
    public var centerX: Double
    public var centerY: Double
    public var easeIn: RationalTime
    public var easeOut: RationalTime
    /// When set, the per-frame zoom centre follows the trajectory instead of
    /// holding the static (`centerX`, `centerY`). Nil for manually-authored
    /// keyframes and for back-compat with pre-2026-05-13 sidecars without
    /// mouse-move samples.
    public var trajectory: [ZoomTrajectorySample]?
    public var origin: ZoomOrigin
    /// Selects between cursor-tracking and pinned-static framing. See
    /// `ZoomAnchorMode`. Defaults to `.followCursor` for back-compat.
    public var anchorMode: ZoomAnchorMode
    /// Shifts the cursor-follow trajectory's start *forward* in time by
    /// this many seconds. Used by gesture-sourced zooms (shake / circle)
    /// to anchor the zoom on the cursor's near-future position rather
    /// than the shake's geometric center — the wiggle is mid-motion, so
    /// the user's intended focal point is where the cursor is *heading*,
    /// not where it was. `PreviewComposition.applyCursorTrajectory`
    /// passes this through to `MouseTrajectory.window` when re-slicing
    /// the damped master trajectory; the resulting `trajectory[0].t`
    /// equals this value, and `EffectEvaluator.zoomCenter`'s
    /// first-sample clamp holds that predicted anchor in place across
    /// the ease-in window. Defaults to 0 (no lookahead) for non-gesture
    /// keyframes and for back-compat with pre-2026-05-17 sidecars.
    public var followLeadSeconds: Double
    public var extras: [String: JSONValue]

    public init(
        id: EffectKeyframeID = .generate(),
        kind: EffectKind,
        timelineRange: TimeRange,
        zoomFactor: Double = 1.5,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        easeIn: RationalTime = .seconds(0.2),
        easeOut: RationalTime = .seconds(0.2),
        trajectory: [ZoomTrajectorySample]? = nil,
        origin: ZoomOrigin = .auto,
        anchorMode: ZoomAnchorMode = .followCursor,
        followLeadSeconds: Double = 0,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.timelineRange = timelineRange
        self.zoomFactor = zoomFactor
        self.centerX = centerX
        self.centerY = centerY
        self.easeIn = easeIn
        self.easeOut = easeOut
        self.trajectory = trajectory
        self.origin = origin
        self.anchorMode = anchorMode
        self.followLeadSeconds = followLeadSeconds
        self.extras = extras
    }

    /// Compute the strength of this keyframe at timeline position `t`
    /// (seconds). 0 outside the range, 1 in the hold portion, smoothly
    /// interpolated through ease-in / ease-out. Pure-data, no Metal /
    /// AVFoundation.
    public func strength(at t: Double) -> Double {
        let start = timelineRange.start.seconds
        let end = timelineRange.end.seconds
        guard t >= start, t < end else { return 0 }
        let local = t - start
        let inDuration = max(0, easeIn.seconds)
        let outDuration = max(0, easeOut.seconds)
        let total = end - start
        // Clamp ease windows so they fit inside the range — if the user
        // configured them too large (e.g. easeIn + easeOut > total) we
        // proportionally shrink them. Avoids a divide-by-zero or
        // negative-hold-window glitch.
        let easeBudget = inDuration + outDuration
        let inEff: Double
        let outEff: Double
        if easeBudget > total {
            let scale = total / easeBudget
            inEff = inDuration * scale
            outEff = outDuration * scale
        } else {
            inEff = inDuration
            outEff = outDuration
        }
        let timeRemaining = total - local
        if inEff > 0, local < inEff {
            return Self.smoothstep(local / inEff)
        }
        if outEff > 0, timeRemaining < outEff {
            return Self.smoothstep(timeRemaining / outEff)
        }
        return 1
    }

    /// Quintic smoothstep — `6x⁵ - 15x⁴ + 10x³`. C² at both endpoints
    /// (zero velocity AND zero acceleration), so the ramp doesn't kick
    /// in at the boundary the way the cubic `3x² - 2x³` form does.
    static func smoothstep(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return c * c * c * (c * (c * 6 - 15) + 10)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case timelineRange
        case zoomFactor
        case centerX
        case centerY
        case easeIn
        case easeOut
        case trajectory
        case origin
        case anchorMode
        case followLeadSeconds
        case extras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(EffectKeyframeID.self, forKey: .id)
        self.kind = try c.decode(EffectKind.self, forKey: .kind)
        self.timelineRange = try c.decode(TimeRange.self, forKey: .timelineRange)
        self.zoomFactor = try c.decode(Double.self, forKey: .zoomFactor)
        self.centerX = try c.decode(Double.self, forKey: .centerX)
        self.centerY = try c.decode(Double.self, forKey: .centerY)
        self.easeIn = try c.decode(RationalTime.self, forKey: .easeIn)
        self.easeOut = try c.decode(RationalTime.self, forKey: .easeOut)
        self.trajectory = try c.decodeIfPresent([ZoomTrajectorySample].self, forKey: .trajectory)
        self.origin = try c.decodeIfPresent(ZoomOrigin.self, forKey: .origin) ?? .auto
        self.anchorMode = try c.decodeIfPresent(ZoomAnchorMode.self, forKey: .anchorMode) ?? .followCursor
        self.followLeadSeconds = try c.decodeIfPresent(Double.self, forKey: .followLeadSeconds) ?? 0
        self.extras = try c.decode([String: JSONValue].self, forKey: .extras)
    }
}
