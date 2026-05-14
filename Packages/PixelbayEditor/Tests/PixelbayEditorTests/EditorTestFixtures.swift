import Foundation
@testable import PixelbayEditor
import PixelbayCore

// Synthetic Project fixture for editor tests. Mirrors the shape of a
// post-recording Phase-1 bundle (one screen track + one webcam track,
// each with a single clip from a single MediaAsset) but without touching
// the filesystem.
enum EditorFixture {
    static let timescale: Int32 = 600

    static func minimalSingleClip() -> (Project, ClipID) {
        let asset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/screen-1.mov",
            captureStart: nil,
            nativeDuration: rt(value: 6000) // 10s
        )
        let clip = Clip(
            id: ClipID.generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(value: 600), duration: rt(value: 4800)), // 1s..9s
            timelineRange: TimeRange(start: rt(value: 0), duration: rt(value: 4800)), // 0..8s
            volume: 0.8,
            speed: 1.0,
            enabled: true
        )
        let track = Track(
            id: TrackID.generate(),
            kind: .screen,
            name: "Screen",
            clips: [clip]
        )
        var project = Project(name: "Fixture")
        project.assets = [asset]
        project.tracks = [track]
        return (project, clip.id)
    }

    /// Two-clip-on-one-track fixture for ordering / move / split tests.
    /// Clip A: timeline 0..4s, source 1..5s.
    /// Clip B: timeline 5..9s, source 0..4s.
    /// Same track, same asset (different source ranges).
    static func twoClipsOneTrack() -> (Project, TrackID, ClipID, ClipID) {
        let asset = MediaAsset(
            id: MediaAssetID.generate(),
            kind: .display,
            relativePath: "media/screen-1.mov",
            captureStart: nil,
            nativeDuration: rt(value: 6000)
        )
        let clipA = Clip(
            id: ClipID.generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(value: 600), duration: rt(value: 2400)),
            timelineRange: TimeRange(start: rt(value: 0), duration: rt(value: 2400)),
            volume: 1.0,
            speed: 1.0
        )
        let clipB = Clip(
            id: ClipID.generate(),
            assetID: asset.id,
            sourceRange: TimeRange(start: rt(value: 0), duration: rt(value: 2400)),
            timelineRange: TimeRange(start: rt(value: 3000), duration: rt(value: 2400)),
            volume: 1.0,
            speed: 1.0
        )
        let track = Track(
            id: TrackID.generate(),
            kind: .screen,
            name: "Screen",
            clips: [clipA, clipB]
        )
        var project = Project(name: "Two-Clip Fixture")
        project.assets = [asset]
        project.tracks = [track]
        return (project, track.id, clipA.id, clipB.id)
    }

    static func rt(value: Int64, timescale: Int32 = EditorFixture.timescale) -> RationalTime {
        RationalTime(value: value, timescale: timescale)
    }
}
