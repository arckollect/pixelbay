import Foundation

// Per-project lane-collapse state for the grouped timeline (Branch B,
// 2026-05-27). The editor renders two collapsed "super-lanes" by default —
// Video (screen + webcam + future overlay tracks) and Audio (microphone +
// systemAudio + voiceover) — and lets the user expand either to the
// underlying physical tracks. This state is per-project and persists
// across editor sessions.
//
// Storage strategy mirrors `MediaAsset.cursorRenderedSynthetically`
// (CursorSettings.swift:64–73): a typed Swift accessor over an
// `extras["…"]` `JSONValue` so we get persistence + forward-compat
// without bumping `schemaVersion`. A pre-Branch-B Pixelbay decoding a
// Branch-B project simply ignores the extras key; we re-emit it on save
// because `JSONValue` preserves the whole extras tree losslessly.

/// Identifies a grouped lane in the timeline. `.effects` doesn't appear
/// here because the effects row is always standalone — only `.video` and
/// `.audio` are user-collapsible. New group kinds added in the future
/// should append a new case + extend `Project+TimelineCollapse`'s
/// stringValue mapping.
public enum LaneGroupID: String, Hashable, Sendable, CaseIterable, Codable {
    case video
    case audio
}

extension Project {
    /// Per-lane collapse state. `true` = lane is collapsed (shows the
    /// grouped band); `false` = expanded (shows underlying physical
    /// tracks). A missing entry falls back to
    /// `timelineLaneCollapseDefault` so the smart-default seed applies to
    /// any lane the user hasn't touched.
    ///
    /// Stored in `extras["timelineLaneCollapse"]` as a JSON object whose
    /// keys are `LaneGroupID.rawValue` and whose values are bools.
    public var timelineLaneCollapse: [LaneGroupID: Bool] {
        get {
            guard case .object(let dict) = extras["timelineLaneCollapse"] else { return [:] }
            var out: [LaneGroupID: Bool] = [:]
            for (key, value) in dict {
                guard let group = LaneGroupID(rawValue: key) else { continue }
                if case .bool(let b) = value {
                    out[group] = b
                }
            }
            return out
        }
        set {
            if newValue.isEmpty {
                extras["timelineLaneCollapse"] = nil
            } else {
                var dict: [String: JSONValue] = [:]
                for (group, value) in newValue {
                    dict[group.rawValue] = .bool(value)
                }
                extras["timelineLaneCollapse"] = .object(dict)
            }
        }
    }

    /// Smart-default seed for lanes the user hasn't explicitly toggled.
    /// `true` (the default) means a fresh project opens with both Video
    /// and Audio lanes collapsed — the user's pick in the original
    /// requirements ("the timeline stays calm by default but can be
    /// drilled into when precision matters"). Returning `true` from the
    /// getter when the key is missing is the migration-free way of
    /// applying this to pre-Branch-B projects on first open.
    public var timelineLaneCollapseDefault: Bool {
        get {
            if case .bool(let b) = extras["timelineLaneCollapseDefault"] { return b }
            return true
        }
        set {
            extras["timelineLaneCollapseDefault"] = .bool(newValue)
        }
    }

    /// Resolves the effective collapse state for a single lane, applying
    /// the per-lane override if present, otherwise the smart-default
    /// seed. Pure-data helper so call sites don't repeat the lookup.
    public func isLaneCollapsed(_ group: LaneGroupID) -> Bool {
        timelineLaneCollapse[group] ?? timelineLaneCollapseDefault
    }
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

extension Track {
    /// When `true`, the track is "broken out" of its `kind.laneGroup` —
    /// it always renders as a standalone row regardless of the group's
    /// collapse state, and edits don't propagate via the collapsed-lane
    /// group commands. Set by the Expand action (disclosure chevron or
    /// Expand-all toolbar button); cleared by the Collapse-all action.
    ///
    /// Storage: `extras["laneBreakout"]` as a JSON bool. Missing key
    /// reads as `false` (track is still in its group). Mirrors
    /// `MediaAsset.cursorRenderedSynthetically`'s typed-accessor pattern.
    public var laneBreakout: Bool {
        get {
            if case .bool(let b) = extras["laneBreakout"] { return b }
            return false
        }
        set {
            if newValue {
                extras["laneBreakout"] = .bool(true)
            } else {
                extras["laneBreakout"] = nil
            }
        }
    }

    /// Resolves a track's effective lane group, accounting for the
    /// `laneBreakout` flag. Returns `nil` for tracks that are broken
    /// out (so they're treated as standalone) and for `.effects`
    /// tracks (which have their own dedicated row).
    public var effectiveLaneGroup: LaneGroupID? {
        if laneBreakout { return nil }
        return kind.laneGroup
    }
}
