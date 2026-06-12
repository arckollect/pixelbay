import Foundation

/// Where the cursor-path smoothing applies. `.fullRecording` renders the
/// synthetic cursor from the smoothed path everywhere (Screen Studio
/// behavior — no visible change in cursor character when a zoom begins).
/// `.zoomsOnly` keeps the cursor true to the raw recording outside zoom
/// segments and blends the smoothing in with each zoom's strength.
public enum SmoothingScope: String, Codable, Sendable, CaseIterable {
    case fullRecording
    case zoomsOnly
}

/// Project-wide motion tuning — the single authority for camera-follow feel,
/// cursor-path smoothing, and motion blur.
///
/// Every field here maps 1:1 onto one slider in the Motion Tuning panel and
/// onto exactly one term in the motion math. Nothing resolves, scales, or
/// overwrites these values downstream — what the slider says is what the
/// solver gets. (This replaces the retired `ZoomFollowStyle` macro sliders,
/// which fanned each control out into many hidden parameters and silently
/// clobbered per-keyframe overrides at every composition rebuild.)
public struct TuningSettings: Codable, Sendable, Equatable {
    // MARK: Camera Feel

    /// Spring time constant in seconds, constant at ALL cursor speeds.
    /// Higher = heavier, floatier camera. The camera must never get
    /// snappier because the cursor sped up.
    public var cameraTau: Double {
        didSet { cameraTau = cameraTau.clamped(to: Self.cameraTauRange) }
    }
    /// 0 = critically damped (no overshoot), 1 = pronounced elastic
    /// drift-past-and-settle. Maps to dampingRatio = 1 − 0.45·settle.
    public var settle: Double {
        didSet { settle = settle.clamped(to: Self.settleRange) }
    }
    /// Radius, as a fraction of the visible zoomed half-frame, where the
    /// camera rests perfectly still while the cursor wanders. Leaving it
    /// triggers a soft full recenter.
    public var deadzoneFraction: Double {
        didSet { deadzoneFraction = deadzoneFraction.clamped(to: Self.deadzoneFractionRange) }
    }
    /// Camera pan speed cap in normalized screen-units per second.
    public var maxPanSpeed: Double {
        didSet { maxPanSpeed = maxPanSpeed.clamped(to: Self.maxPanSpeedRange) }
    }
    /// Seconds of lead on the (already smoothed) cursor path — the camera
    /// aims slightly ahead of the cursor. Rendering is post-hoc, so the
    /// future is known.
    public var lookaheadSeconds: Double {
        didSet { lookaheadSeconds = lookaheadSeconds.clamped(to: Self.lookaheadSecondsRange) }
    }

    // MARK: Cursor Path

    /// Half-width of the zero-phase smoothing window over the cursor path.
    /// Larger windows both slow AND shrink fast motion (amplitude collapse).
    public var pathWindowSeconds: Double {
        didSet { pathWindowSeconds = pathWindowSeconds.clamped(to: Self.pathWindowSecondsRange) }
    }
    /// How much fast travel may deviate from the raw path, 0 = stay honest,
    /// 1 = fully collapse edge-to-edge spam into the window mean.
    public var travelCollapse: Double {
        didSet { travelCollapse = travelCollapse.clamped(to: Self.travelCollapseRange) }
    }
    /// Ease window (seconds) around each recorded click inside which the
    /// smoothed path blends back to the raw cursor position — exactly raw
    /// at the click instant.
    public var clickSnapWindow: Double {
        didSet { clickSnapWindow = clickSnapWindow.clamped(to: Self.clickSnapWindowRange) }
    }
    public var smoothingScope: SmoothingScope

    // MARK: Motion Blur

    /// Camera shutter angle in degrees (film convention; 180° = shutter
    /// open half the frame interval). Drives the temporal blur window.
    public var shutterAngle: Double {
        didSet { shutterAngle = shutterAngle.clamped(to: Self.shutterAngleRange) }
    }
    /// Master multiplier on the sampled camera-transform delta. 0 disables
    /// screen motion blur entirely.
    public var blurStrength: Double {
        didSet { blurStrength = blurStrength.clamped(to: Self.blurStrengthRange) }
    }
    /// Scales the cursor sprite's shutter so sprite and screen blur agree.
    public var cursorBlur: Double {
        didSet { cursorBlur = cursorBlur.clamped(to: Self.cursorBlurRange) }
    }

    // MARK: Transition

    /// Blends the zoom in/out strength curve from quintic smoothstep (0)
    /// toward a longer, softer tail (1).
    public var transitionSoftness: Double {
        didSet { transitionSoftness = transitionSoftness.clamped(to: Self.transitionSoftnessRange) }
    }

    // MARK: Ranges

    public static let cameraTauRange: ClosedRange<Double> = 0.10...0.80
    public static let settleRange: ClosedRange<Double> = 0.0...1.0
    public static let deadzoneFractionRange: ClosedRange<Double> = 0.0...0.6
    public static let maxPanSpeedRange: ClosedRange<Double> = 0.3...2.5
    public static let lookaheadSecondsRange: ClosedRange<Double> = 0.0...0.15
    public static let pathWindowSecondsRange: ClosedRange<Double> = 0.0...0.6
    public static let travelCollapseRange: ClosedRange<Double> = 0.0...1.0
    public static let clickSnapWindowRange: ClosedRange<Double> = 0.05...0.4
    public static let shutterAngleRange: ClosedRange<Double> = 0.0...360.0
    public static let blurStrengthRange: ClosedRange<Double> = 0.0...2.0
    public static let cursorBlurRange: ClosedRange<Double> = 0.0...1.0
    public static let transitionSoftnessRange: ClosedRange<Double> = 0.0...1.0

    public static let `default` = TuningSettings()

    public init(
        cameraTau: Double = 0.35,
        settle: Double = 0.25,
        deadzoneFraction: Double = 0.35,
        maxPanSpeed: Double = 0.9,
        lookaheadSeconds: Double = 0.04,
        pathWindowSeconds: Double = 0.35,
        travelCollapse: Double = 0.7,
        clickSnapWindow: Double = 0.15,
        smoothingScope: SmoothingScope = .fullRecording,
        shutterAngle: Double = 180,
        blurStrength: Double = 1.0,
        cursorBlur: Double = 0.6,
        transitionSoftness: Double = 0.5
    ) {
        self.cameraTau = cameraTau.clamped(to: Self.cameraTauRange)
        self.settle = settle.clamped(to: Self.settleRange)
        self.deadzoneFraction = deadzoneFraction.clamped(to: Self.deadzoneFractionRange)
        self.maxPanSpeed = maxPanSpeed.clamped(to: Self.maxPanSpeedRange)
        self.lookaheadSeconds = lookaheadSeconds.clamped(to: Self.lookaheadSecondsRange)
        self.pathWindowSeconds = pathWindowSeconds.clamped(to: Self.pathWindowSecondsRange)
        self.travelCollapse = travelCollapse.clamped(to: Self.travelCollapseRange)
        self.clickSnapWindow = clickSnapWindow.clamped(to: Self.clickSnapWindowRange)
        self.smoothingScope = smoothingScope
        self.shutterAngle = shutterAngle.clamped(to: Self.shutterAngleRange)
        self.blurStrength = blurStrength.clamped(to: Self.blurStrengthRange)
        self.cursorBlur = cursorBlur.clamped(to: Self.cursorBlurRange)
        self.transitionSoftness = transitionSoftness.clamped(to: Self.transitionSoftnessRange)
    }

    private enum CodingKeys: String, CodingKey {
        case cameraTau
        case settle
        case deadzoneFraction
        case maxPanSpeed
        case lookaheadSeconds
        case pathWindowSeconds
        case travelCollapse
        case clickSnapWindow
        case smoothingScope
        case shutterAngle
        case blurStrength
        case cursorBlur
        case transitionSoftness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.init(
            cameraTau: try c.decodeIfPresent(Double.self, forKey: .cameraTau) ?? d.cameraTau,
            settle: try c.decodeIfPresent(Double.self, forKey: .settle) ?? d.settle,
            deadzoneFraction: try c.decodeIfPresent(Double.self, forKey: .deadzoneFraction) ?? d.deadzoneFraction,
            maxPanSpeed: try c.decodeIfPresent(Double.self, forKey: .maxPanSpeed) ?? d.maxPanSpeed,
            lookaheadSeconds: try c.decodeIfPresent(Double.self, forKey: .lookaheadSeconds) ?? d.lookaheadSeconds,
            pathWindowSeconds: try c.decodeIfPresent(Double.self, forKey: .pathWindowSeconds) ?? d.pathWindowSeconds,
            travelCollapse: try c.decodeIfPresent(Double.self, forKey: .travelCollapse) ?? d.travelCollapse,
            clickSnapWindow: try c.decodeIfPresent(Double.self, forKey: .clickSnapWindow) ?? d.clickSnapWindow,
            smoothingScope: try c.decodeIfPresent(SmoothingScope.self, forKey: .smoothingScope) ?? d.smoothingScope,
            shutterAngle: try c.decodeIfPresent(Double.self, forKey: .shutterAngle) ?? d.shutterAngle,
            blurStrength: try c.decodeIfPresent(Double.self, forKey: .blurStrength) ?? d.blurStrength,
            cursorBlur: try c.decodeIfPresent(Double.self, forKey: .cursorBlur) ?? d.cursorBlur,
            transitionSoftness: try c.decodeIfPresent(Double.self, forKey: .transitionSoftness) ?? d.transitionSoftness
        )
    }

    /// Swift source literal of the current values — the Motion Tuning
    /// panel's "Copy Values" button puts this on the pasteboard so a feel
    /// the user likes can be pasted back as the new hardcoded defaults.
    public var swiftLiteral: String {
        """
        TuningSettings(
            cameraTau: \(formatted(cameraTau)),
            settle: \(formatted(settle)),
            deadzoneFraction: \(formatted(deadzoneFraction)),
            maxPanSpeed: \(formatted(maxPanSpeed)),
            lookaheadSeconds: \(formatted(lookaheadSeconds)),
            pathWindowSeconds: \(formatted(pathWindowSeconds)),
            travelCollapse: \(formatted(travelCollapse)),
            clickSnapWindow: \(formatted(clickSnapWindow)),
            smoothingScope: .\(smoothingScope.rawValue),
            shutterAngle: \(formatted(shutterAngle)),
            blurStrength: \(formatted(blurStrength)),
            cursorBlur: \(formatted(cursorBlur)),
            transitionSoftness: \(formatted(transitionSoftness))
        )
        """
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
