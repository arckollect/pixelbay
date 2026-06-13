import CoreGraphics
import Foundation

/// Reference-tuned zoom/follow constants.
///
/// Ported from siddharthvaddem/openscreen
/// (`src/components/video-editor/videoPlayback/*`,
/// `src/components/video-editor/timeline/zoomSuggestionUtils.ts`), MIT.
public enum ZoomMotionConstants {
    public static let defaultFocus = ZoomFocus(cx: 0.5, cy: 0.5)
    public static let transitionWindowMs: Double = 1015.05
    public static let zoomInTransitionWindowMs: Double = transitionWindowMs * 1.5
    public static let minDelta: Double = 0.0001
    public static let viewportScale: Double = 0.8
    public static let smoothingFactor: Double = 0.12
    public static let zoomTranslationDeadzonePx: Double = 1.25
    public static let zoomScaleDeadzone: Double = 0.002

    public static let autoFollowSmoothingFactor: Double = 0.1
    public static let autoFollowSmoothingFactorMax: Double = 0.25
    public static let autoFollowRampDistance: Double = 0.15
    public static let autoFollowReferenceMs: Double = 1000.0 / 40.0

    public static let autoFollowParams = FollowParams(
        minFactor: autoFollowSmoothingFactor,
        maxFactor: autoFollowSmoothingFactorMax,
        rampDistance: autoFollowRampDistance,
        referenceMs: autoFollowReferenceMs
    )

    public static let minDwellDurationMs: Double = 450
    public static let maxDwellDurationMs: Double = 2600
    public static let dwellMoveThreshold: Double = 0.02
    public static let suggestionSpacingMs: Double = 1800
}

public struct ZoomFocus: Sendable, Equatable {
    public var cx: Double
    public var cy: Double

    public init(cx: Double, cy: Double) {
        self.cx = cx
        self.cy = cy
    }
}

/// Timestamped cursor telemetry in normalized stage coordinates.
public struct CursorTelemetryPoint: Sendable, Equatable {
    public var timeMs: Double
    public var cx: Double
    public var cy: Double
    public var interactionType: String?
    public var cursorType: String?

    public init(
        timeMs: Double,
        cx: Double,
        cy: Double,
        interactionType: String? = nil,
        cursorType: String? = nil
    ) {
        self.timeMs = timeMs
        self.cx = cx
        self.cy = cy
        self.interactionType = interactionType
        self.cursorType = cursorType
    }
}

public struct FollowParams: Sendable, Equatable {
    public var minFactor: Double
    public var maxFactor: Double
    public var rampDistance: Double
    public var referenceMs: Double

    public init(minFactor: Double, maxFactor: Double, rampDistance: Double, referenceMs: Double) {
        self.minFactor = minFactor
        self.maxFactor = maxFactor
        self.rampDistance = rampDistance
        self.referenceMs = referenceMs
    }
}

public enum CursorFollow {
    /// Binary-search sorted telemetry and linearly interpolate cursor focus at `timeMs`.
    public static func interpolateCursorAt(
        _ telemetry: [CursorTelemetryPoint],
        timeMs: Double
    ) -> ZoomFocus? {
        guard let first = telemetry.first else { return nil }
        if timeMs <= first.timeMs {
            return ZoomFocus(cx: first.cx, cy: first.cy)
        }
        guard let last = telemetry.last else { return nil }
        if timeMs >= last.timeMs {
            return ZoomFocus(cx: last.cx, cy: last.cy)
        }

        var lo = 0
        var hi = telemetry.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) >> 1
            if telemetry[mid].timeMs <= timeMs {
                lo = mid
            } else {
                hi = mid
            }
        }

        let before = telemetry[lo]
        let after = telemetry[hi]
        let span = after.timeMs - before.timeMs
        let t = span > 0 ? (timeMs - before.timeMs) / span : 0
        return ZoomFocus(
            cx: before.cx + (after.cx - before.cx) * t,
            cy: before.cy + (after.cy - before.cy) * t
        )
    }

    public static func smoothCursorFocus(
        raw: ZoomFocus,
        previous: ZoomFocus,
        factor: Double
    ) -> ZoomFocus {
        ZoomFocus(
            cx: previous.cx + (raw.cx - previous.cx) * factor,
            cy: previous.cy + (raw.cy - previous.cy) * factor
        )
    }

    public static func adaptiveSmoothFactor(
        raw: ZoomFocus,
        previous: ZoomFocus,
        minFactor: Double,
        maxFactor: Double,
        rampDistance: Double
    ) -> Double {
        let dx = raw.cx - previous.cx
        let dy = raw.cy - previous.cy
        let distance = (dx * dx + dy * dy).squareRoot()
        let t = min(1.0, distance / rampDistance)
        return minFactor + (maxFactor - minFactor) * t
    }

    public static func timeCorrectedFollowFactor(
        baseFactor: Double,
        dtMs: Double,
        referenceMs: Double
    ) -> Double {
        guard dtMs > 0, referenceMs > 0 else { return 0 }
        return 1.0 - pow(1.0 - baseFactor, dtMs / referenceMs)
    }

    public static func advanceFollowFocus(
        previous: ZoomFocus,
        raw: ZoomFocus,
        dtMs: Double,
        params: FollowParams = ZoomMotionConstants.autoFollowParams
    ) -> ZoomFocus {
        guard dtMs > 0 else { return previous }
        let base = adaptiveSmoothFactor(
            raw: raw,
            previous: previous,
            minFactor: params.minFactor,
            maxFactor: params.maxFactor,
            rampDistance: params.rampDistance
        )
        let factor = timeCorrectedFollowFactor(
            baseFactor: base,
            dtMs: dtMs,
            referenceMs: params.referenceMs
        )
        return smoothCursorFocus(raw: raw, previous: previous, factor: factor)
    }
}

public struct AppliedZoomTransform: Sendable, Equatable {
    public var scale: Double
    public var x: Double
    public var y: Double

    public init(scale: Double, x: Double, y: Double) {
        self.scale = scale
        self.x = x
        self.y = y
    }
}

public enum ZoomTransformMath {
    public static func computeZoomTransform(
        stageSize: CGSize,
        zoomScale: Double,
        zoomProgress: Double = 1,
        focus: ZoomFocus
    ) -> AppliedZoomTransform {
        guard stageSize.width > 0, stageSize.height > 0 else {
            return AppliedZoomTransform(scale: 1, x: 0, y: 0)
        }
        let progress = min(1.0, max(0.0, zoomProgress))
        let focusStagePxX = focus.cx * Double(stageSize.width)
        let focusStagePxY = focus.cy * Double(stageSize.height)
        let stageCenterX = Double(stageSize.width) / 2.0
        let stageCenterY = Double(stageSize.height) / 2.0
        let scale = 1.0 + (zoomScale - 1.0) * progress
        let finalX = stageCenterX - focusStagePxX * zoomScale
        let finalY = stageCenterY - focusStagePxY * zoomScale
        return AppliedZoomTransform(scale: scale, x: finalX * progress, y: finalY * progress)
    }

    public static func computeFocusFromTransform(
        stageSize: CGSize,
        zoomScale: Double,
        x: Double,
        y: Double
    ) -> ZoomFocus {
        guard stageSize.width > 0, stageSize.height > 0, zoomScale > 0 else {
            return ZoomMotionConstants.defaultFocus
        }
        let stageCenterX = Double(stageSize.width) / 2.0
        let stageCenterY = Double(stageSize.height) / 2.0
        return ZoomFocus(
            cx: ((stageCenterX - x) / zoomScale) / Double(stageSize.width),
            cy: ((stageCenterY - y) / zoomScale) / Double(stageSize.height)
        )
    }
}

public struct SpringState: Sendable, Equatable {
    public var value: Double
    public var velocity: Double
    public var initialized: Bool

    public init(value: Double = 0, velocity: Double = 0, initialized: Bool = false) {
        self.value = value
        self.velocity = velocity
        self.initialized = initialized
    }
}

public struct SpringConfig: Sendable, Equatable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double
    public var restDelta: Double
    public var restSpeed: Double

    public init(
        stiffness: Double,
        damping: Double,
        mass: Double,
        restDelta: Double = 0.0005,
        restSpeed: Double = 0.02
    ) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        self.restDelta = restDelta
        self.restSpeed = restSpeed
    }
}

public enum MotionSpring {
    public static func createSpringState(initialValue: Double = 0) -> SpringState {
        SpringState(value: initialValue)
    }

    public static func getZoomSpringConfig() -> SpringConfig {
        SpringConfig(
            stiffness: 320,
            damping: 40,
            mass: 0.92,
            restDelta: 0.0005,
            restSpeed: 0.015
        )
    }

    public static func clampDeltaMs(_ deltaMs: Double, fallbackMs: Double = 1000.0 / 60.0) -> Double {
        guard deltaMs.isFinite, deltaMs > 0 else { return fallbackMs }
        return min(80, max(1, deltaMs))
    }

    public static func stepSpringValue(
        state: inout SpringState,
        target: Double,
        deltaMs: Double,
        config: SpringConfig
    ) -> Double {
        let safeDeltaMs = clampDeltaMs(deltaMs)
        guard state.initialized, state.value.isFinite else {
            state.value = target
            state.velocity = 0
            state.initialized = true
            return state.value
        }

        if abs(target - state.value) <= config.restDelta,
           abs(state.velocity) <= config.restSpeed {
            state.value = target
            state.velocity = 0
            return state.value
        }

        let previous = state.value
        var remaining = safeDeltaMs / 1000.0
        let maxStep = 1.0 / 240.0
        while remaining > 0 {
            let dt = min(maxStep, remaining)
            let displacement = state.value - target
            let acceleration = (-config.stiffness * displacement - config.damping * state.velocity) / config.mass
            state.velocity += acceleration * dt
            state.value += state.velocity * dt
            remaining -= dt
        }
        if abs(target - state.value) <= config.restDelta,
           abs(state.velocity) <= config.restSpeed {
            state.value = target
            state.velocity = 0
        } else {
            state.velocity = (state.value - previous) / (safeDeltaMs / 1000.0)
        }
        return state.value
    }
}

public struct ZoomSpringState: Sendable, Equatable {
    public var scale: SpringState
    public var x: SpringState
    public var y: SpringState

    public init(scale: SpringState, x: SpringState, y: SpringState) {
        self.scale = scale
        self.x = x
        self.y = y
    }
}

public enum ZoomSpring {
    public static func createZoomSpringState() -> ZoomSpringState {
        ZoomSpringState(
            scale: MotionSpring.createSpringState(initialValue: 1),
            x: MotionSpring.createSpringState(initialValue: 0),
            y: MotionSpring.createSpringState(initialValue: 0)
        )
    }

    public static func resetZoomSpring(
        state: inout ZoomSpringState,
        target: AppliedZoomTransform
    ) {
        state.scale = SpringState(value: target.scale, velocity: 0, initialized: true)
        state.x = SpringState(value: target.x, velocity: 0, initialized: true)
        state.y = SpringState(value: target.y, velocity: 0, initialized: true)
    }

    public static func stepZoomSpring(
        state: inout ZoomSpringState,
        target: AppliedZoomTransform,
        deltaMs: Double
    ) -> AppliedZoomTransform {
        let config = MotionSpring.getZoomSpringConfig()
        return AppliedZoomTransform(
            scale: stepAxis(&state.scale, target: target.scale, deltaMs: deltaMs, config: config),
            x: stepAxis(&state.x, target: target.x, deltaMs: deltaMs, config: config),
            y: stepAxis(&state.y, target: target.y, deltaMs: deltaMs, config: config)
        )
    }

    private static func stepAxis(
        _ axis: inout SpringState,
        target: Double,
        deltaMs: Double,
        config: SpringConfig
    ) -> Double {
        let before = axis.initialized ? axis.value : target
        let after = MotionSpring.stepSpringValue(
            state: &axis,
            target: target,
            deltaMs: deltaMs,
            config: config
        )
        let crossed = (before <= target && after > target) || (before >= target && after < target)
        if crossed {
            axis.value = target
            axis.velocity = 0
            return target
        }
        return after
    }
}

public struct ZoomDwellCandidate: Sendable, Equatable {
    public var centerTimeMs: Double
    public var focus: ZoomFocus
    public var strength: Double

    public init(centerTimeMs: Double, focus: ZoomFocus, strength: Double) {
        self.centerTimeMs = centerTimeMs
        self.focus = focus
        self.strength = strength
    }
}

public struct AutoZoomSuggestion: Sendable, Equatable {
    public var span: TimeRange
    public var focus: ZoomFocus

    public init(span: TimeRange, focus: ZoomFocus) {
        self.span = span
        self.focus = focus
    }
}

public enum AutoZoomDwellDetector {
    public static func normalizeCursorTelemetry(
        _ telemetry: [CursorTelemetryPoint],
        totalMs: Double
    ) -> [CursorTelemetryPoint] {
        telemetry
            .filter { $0.timeMs.isFinite && $0.cx.isFinite && $0.cy.isFinite }
            .sorted { $0.timeMs < $1.timeMs }
            .map { sample in
                CursorTelemetryPoint(
                    timeMs: min(max(sample.timeMs, 0), totalMs),
                    cx: min(max(sample.cx, 0), 1),
                    cy: min(max(sample.cy, 0), 1),
                    interactionType: sample.interactionType,
                    cursorType: sample.cursorType
                )
            }
    }

    public static func detectZoomDwellCandidates(
        _ samples: [CursorTelemetryPoint]
    ) -> [ZoomDwellCandidate] {
        guard samples.count >= 2 else { return [] }
        var candidates: [ZoomDwellCandidate] = []
        var runStart = 0

        func pushRunIfDwell(startIndex: Int, endIndexExclusive: Int) {
            guard endIndexExclusive - startIndex >= 2 else { return }
            let start = samples[startIndex]
            let end = samples[endIndexExclusive - 1]
            let duration = end.timeMs - start.timeMs
            guard duration >= ZoomMotionConstants.minDwellDurationMs,
                  duration <= ZoomMotionConstants.maxDwellDurationMs else { return }
            let run = samples[startIndex..<endIndexExclusive]
            let sum = run.reduce((cx: 0.0, cy: 0.0)) { acc, sample in
                (acc.cx + sample.cx, acc.cy + sample.cy)
            }
            let count = Double(run.count)
            candidates.append(ZoomDwellCandidate(
                centerTimeMs: ((start.timeMs + end.timeMs) / 2.0).rounded(),
                focus: ZoomFocus(cx: sum.cx / count, cy: sum.cy / count),
                strength: duration
            ))
        }

        for index in 1..<samples.count {
            let prev = samples[index - 1]
            let curr = samples[index]
            let distance = hypot(curr.cx - prev.cx, curr.cy - prev.cy)
            if distance > ZoomMotionConstants.dwellMoveThreshold {
                pushRunIfDwell(startIndex: runStart, endIndexExclusive: index)
                runStart = index
            }
        }
        pushRunIfDwell(startIndex: runStart, endIndexExclusive: samples.count)
        return candidates
    }

    public static func buildAutoZoomSuggestions(
        cursorTelemetry: [CursorTelemetryPoint],
        totalMs: Double,
        existingRegions: [TimeRange],
        defaultDurationMs: Double
    ) -> [AutoZoomSuggestion] {
        guard totalMs > 0, cursorTelemetry.count >= 2 else { return [] }
        let defaultDuration = min(defaultDurationMs, totalMs)
        guard defaultDuration > 0 else { return [] }
        let normalized = normalizeCursorTelemetry(cursorTelemetry, totalMs: totalMs)
        guard normalized.count >= 2 else { return [] }
        let candidates = detectZoomDwellCandidates(normalized).sorted { $0.strength > $1.strength }
        guard !candidates.isEmpty else { return [] }

        var reserved = existingRegions.map { ($0.start.seconds * 1000.0, $0.end.seconds * 1000.0) }
            .sorted { $0.0 < $1.0 }
        var acceptedCenters: [Double] = []
        var suggestions: [AutoZoomSuggestion] = []

        for candidate in candidates {
            if acceptedCenters.contains(where: { abs($0 - candidate.centerTimeMs) < ZoomMotionConstants.suggestionSpacingMs }) {
                continue
            }
            let centeredStart = (candidate.centerTimeMs - defaultDuration / 2.0).rounded()
            let candidateStart = max(0, min(centeredStart, totalMs - defaultDuration))
            let candidateEnd = candidateStart + defaultDuration
            let overlaps = reserved.contains { span in
                candidateEnd > span.0 && candidateStart < span.1
            }
            if overlaps { continue }
            reserved.append((candidateStart, candidateEnd))
            acceptedCenters.append(candidate.centerTimeMs)
            suggestions.append(AutoZoomSuggestion(
                span: TimeRange(
                    start: .seconds(candidateStart / 1000.0),
                    duration: .seconds(defaultDuration / 1000.0)
                ),
                focus: candidate.focus
            ))
        }
        return suggestions
    }
}

public extension MouseTrajectory {
    /// Reference-style adaptive cursor follow over keyframe-local samples.
    static func adaptiveFollow(
        _ samples: [ZoomTrajectorySample],
        params: FollowParams = ZoomMotionConstants.autoFollowParams
    ) -> [ZoomTrajectorySample] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return samples }
        var focus = ZoomFocus(cx: first.x, cy: first.y)
        var previousTimeMs = first.t * 1000.0
        var result: [ZoomTrajectorySample] = [first]
        result.reserveCapacity(samples.count)
        for sample in samples.dropFirst() {
            let timeMs = sample.t * 1000.0
            let raw = ZoomFocus(cx: sample.x, cy: sample.y)
            focus = CursorFollow.advanceFollowFocus(
                previous: focus,
                raw: raw,
                dtMs: timeMs - previousTimeMs,
                params: params
            )
            previousTimeMs = timeMs
            result.append(ZoomTrajectorySample(t: sample.t, x: focus.cx, y: focus.cy))
        }
        return result
    }
}

