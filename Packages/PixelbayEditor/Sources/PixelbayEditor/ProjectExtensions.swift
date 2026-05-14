import Foundation
import PixelbayCore

// Lookup helpers commands depend on. Live in the editor package (not Core)
// because Core is the schema layer — adding ID-based lookups there would
// pull editor concerns into the model. Tests can build Projects directly
// and check these via the public surface.

public extension Project {
    /// Locates a clip by ID. Returns the `(track index, clip index)` tuple
    /// so callers can mutate without re-searching. Nil if the clip isn't
    /// present in any track.
    func locateClip(_ id: ClipID) -> (trackIndex: Int, clipIndex: Int)? {
        for (trackIdx, track) in tracks.enumerated() {
            if let clipIdx = track.clips.firstIndex(where: { $0.id == id }) {
                return (trackIdx, clipIdx)
            }
        }
        return nil
    }

    /// Returns a copy of the clip with the given ID, or nil if not present.
    func clip(_ id: ClipID) -> Clip? {
        guard let (t, c) = locateClip(id) else { return nil }
        return tracks[t].clips[c]
    }

    /// Returns the index of the track with the given ID, or nil.
    func locateTrack(_ id: TrackID) -> Int? {
        tracks.firstIndex(where: { $0.id == id })
    }

    /// In-place mutation of the clip with the given ID. Throws
    /// `.clipNotFound` if the clip isn't found. The closure receives an
    /// `inout Clip` and may mutate any field; the schema invariants the
    /// editor commands depend on are validated by the calling command,
    /// not here.
    mutating func mutateClip(_ id: ClipID, _ body: (inout Clip) throws -> Void) throws {
        guard let (t, c) = locateClip(id) else { throw EditError.clipNotFound(id) }
        try body(&tracks[t].clips[c])
    }
}

public extension Track {
    /// Inserts `clip` into `clips`, maintaining ascending order by
    /// `timelineRange.start.value` (assuming a shared timescale across
    /// the track — true in v0.1, where everything uses 600). Returns the
    /// index the clip landed at so callers can carry the position
    /// forward in their inverse commands.
    @discardableResult
    mutating func insertClipMaintainingOrder(_ clip: Clip) -> Int {
        let target = clips.firstIndex { existing in
            // Tied starts: append after existing clip with the same start
            // (stable behaviour for the inverse path that re-inserts).
            existing.timelineRange.start.value > clip.timelineRange.start.value
        } ?? clips.endIndex
        clips.insert(clip, at: target)
        return target
    }
}
