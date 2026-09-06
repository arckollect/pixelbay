import Foundation

// Lane grouping for the timeline. The editor renders exactly three rows —
// Video (screen + webcam + overlay), Audio (microphone + systemAudio +
// voiceover), and Effects — and every physical track folds into one of
// them by kind. There is no per-project expand/collapse state: the grouped
// rows are the only view. Editing a grouped row's primary clip propagates
// to the overlapping clips on the group's other tracks (see
// `EditCommands+GroupedTimeline.swift`). Showing the webcam full-frame for a
// stretch of the recording is an effect (`EffectKind.talkingHeadSwap`), not
// a separate timeline row.

/// Identifies a grouped lane in the timeline. `.effects` doesn't appear
/// here because the effects row is always standalone.
public enum LaneGroupID: String, Hashable, Sendable, CaseIterable, Codable {
    case video
    case audio
}

extension TrackKind {
    /// Maps a physical track kind to its grouped-lane bucket. `nil`
    /// means the track renders as its own standalone row (currently only
    /// `.effects`, which gets the dedicated effects lane — handled
    /// separately by the timeline renderer).
    ///
    /// Future track kinds should pick one of the two existing groups
    /// rather than introducing a third unless there's a strong reason
    /// (the user picked "by media type", not "by source").
    public var laneGroup: LaneGroupID? {
        switch self {
        case .screen, .webcam, .overlay:
            return .video
        case .microphone, .systemAudio, .voiceover:
            return .audio
        case .effects:
            return nil
        }
    }
}
