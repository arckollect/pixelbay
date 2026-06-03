import Foundation

// Shared timecode formatting. Previously duplicated as a private
// `formatTime` in ProjectView / EffectsInspector / PostCaptureView with two
// slightly different formats — consolidated here so transport bars, keyframe
// readouts and capture summaries stay consistent. Pair with
// `Theme.Font.monoTimecode` for the monospaced render.

public enum Timecode {
    /// `M:SS` — coarse transport / duration readout (e.g. "1:23"). Negative
    /// or non-finite input renders as "0:00".
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `M:SS.ff` — sub-second precision for keyframe / scrub readouts
    /// (e.g. "1:23.45"). Negative or non-finite input renders as "0:00.00".
    public static func precise(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", minutes, secs)
    }
}
