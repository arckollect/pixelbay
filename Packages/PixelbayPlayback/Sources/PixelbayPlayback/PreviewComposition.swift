#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import PixelbayCompositor
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "PreviewComposition")

// Builds an AVMutableComposition + AVMutableVideoComposition + AVAudioMix
// from a `Project` for the post-capture preview surface. Per HANDOFF §6.6
// the same composition drives export — there's no parallel "export" path
// that could drift.
//
// Honours every Phase-2 edit: each track's clips contribute their own
// `sourceRange` slice of the underlying asset, inserted at the clip's
// `timelineRange.start` on a single composition track per Pixelbay
// track. Per-clip volume becomes setVolumeRamp segments on an
// AVMutableAudioMix bound to the matching track.
//
// Output size is taken from the screen video's natural size, capped at
// 1920×1080 — matches what LiveCaptureBackend records (HANDOFF §6.5).

public struct PreviewComposition: @unchecked Sendable {
    public var composition: AVComposition
    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    public var duration: CMTime
    public var outputSize: CGSize
    public var hasVideo: Bool { videoComposition != nil }

    public init(
        composition: AVComposition,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        duration: CMTime,
        outputSize: CGSize
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.outputSize = outputSize
    }
}

public enum PreviewCompositionError: Error, LocalizedError {
    case noScreenAsset
    case fileNotFound(URL)
    case noVideoTrack(URL)

    public var errorDescription: String? {
        switch self {
        case .noScreenAsset: return "Project has no screen recording asset to preview."
        case .fileNotFound(let url): return "Media file not found: \(url.lastPathComponent)"
        case .noVideoTrack(let url): return "No video track found in \(url.lastPathComponent)"
        }
    }
}

public enum PreviewCompositionBuilder {
    // Default Phase 1 output size; capped at 1920×1080 per HANDOFF §6.5.
    public static let defaultOutputSize = CGSize(width: 1920, height: 1080)

    /// Builds a PreviewComposition from a Project. `bundleURL` is the
    /// `.pixelbay` bundle's directory — `MediaAsset.relativePath`
    /// resolves against it.
    ///
    /// Iterates each track's clips and inserts each clip's `sourceRange`
    /// slice of the asset's source track at the clip's
    /// `timelineRange.start`. Audio clips' `volume` becomes a
    /// `setVolumeRamp` segment on an `AVMutableAudioMix`.
    ///
    /// Failure modes:
    ///   • Project has no screen track with at least one clip → `.noScreenAsset`.
    ///   • Asset file missing → `.fileNotFound`.
    ///   • Source has no video track for a video asset → `.noVideoTrack`.
    /// Audio clips with missing files / no audio track are silently skipped
    /// (one missing mic.caf shouldn't break preview of screen + cam).
    public static func build(
        project: Project,
        bundleURL: URL,
        wallpaperSource: WallpaperSource? = nil,
        cursorTrajectory: [MouseTrajectorySample]? = nil,
        cursorSprite: CursorSpriteData? = nil
    ) async throws -> PreviewComposition {
        let composition = AVMutableComposition()

        var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        var webcamTrackID: CMPersistentTrackID?
        var screenSize: CGSize = .zero
        var screenAdded = false
        var maxTimelineEnd: CMTime = .zero
        var audioMixInputParams: [AVMutableAudioMixInputParameters] = []

        for track in project.tracks where !track.clips.isEmpty {
            for clip in track.clips {
                let end = CMTimeAdd(cmTime(clip.timelineRange.start), cmTime(clip.timelineRange.duration))
                if CMTimeCompare(end, maxTimelineEnd) > 0 {
                    maxTimelineEnd = end
                }
            }

            switch track.kind {
            case .screen:
                let result = try await populateVideoTrack(
                    composition: composition,
                    track: track,
                    project: project,
                    bundleURL: bundleURL
                )
                screenTrackID = result.trackID
                screenSize = result.firstNaturalSize
                screenAdded = true

            case .webcam:
                do {
                    let result = try await populateVideoTrack(
                        composition: composition,
                        track: track,
                        project: project,
                        bundleURL: bundleURL
                    )
                    webcamTrackID = result.trackID
                } catch {
                    log.error("webcam track add failed (continuing screen-only): \(String(describing: error), privacy: .public)")
                }

            case .microphone, .systemAudio, .voiceover:
                do {
                    let inputParams = try await populateAudioTrack(
                        composition: composition,
                        track: track,
                        project: project,
                        bundleURL: bundleURL
                    )
                    if let inputParams { audioMixInputParams.append(inputParams) }
                } catch {
                    log.error("audio track add failed (continuing): \(String(describing: error), privacy: .public)")
                }

            case .overlay, .effects:
                // Phase 3+: text overlays + effect tracks. Compositor
                // doesn't render them yet; skip silently.
                continue
            }
        }

        guard screenAdded else { throw PreviewCompositionError.noScreenAsset }

        let duration = maxTimelineEnd
        let outputSize = computeOutputSize(from: screenSize)
        let resolvedPreset = wallpaperSource?.resolve(project.layout) ?? project.layout
        let effects = applyCursorTrajectory(
            to: project.effects,
            cursorTrajectory: cursorTrajectory
        )
        // Phase 3c — only enable the synthetic cursor pass when the screen
        // asset was captured with `showsCursor = false` (flagged via
        // `MediaAsset.cursorRenderedSynthetically`). Legacy recordings
        // have the OS cursor baked in, so drawing on top would produce a
        // double cursor; we keep `cursorTrajectoryForRender` empty in
        // that case and the compositor skips the pass.
        let cursorSyntheticallyRendered = project.assets.contains { asset in
            asset.kind == .display && asset.cursorRenderedSynthetically
        }
        let cursorTrajectoryForRender: [MouseTrajectorySample]
        if cursorSyntheticallyRendered, let master = cursorTrajectory, !master.isEmpty {
            // No EMA here. The auto-zoom path uses smoothed() because a
            // 1.6× zoom amplifies sub-sample velocity discontinuities; the
            // sprite renders 1:1 against the screen rect so amplification
            // doesn't apply, and EMA at α=0.22 over 30/60 Hz samples adds
            // ~50–120 ms of steady-state lag — the cursor visibly trails
            // the actual motion. The compositor's Catmull-Rom interp
            // already gives C¹ continuity across sample boundaries, which
            // is what we actually need.
            cursorTrajectoryForRender = master
        } else {
            cursorTrajectoryForRender = []
        }
        let videoComposition = makeVideoComposition(
            duration: duration,
            outputSize: outputSize,
            layoutPreset: resolvedPreset,
            effects: effects,
            screenTrackID: screenTrackID,
            webcamTrackID: webcamTrackID,
            cursorSprite: cursorSyntheticallyRendered ? cursorSprite : nil,
            cursorSettings: cursorSyntheticallyRendered ? project.cursorSettings : nil,
            cursorTrajectory: cursorTrajectoryForRender
        )
        let audioMix: AVAudioMix?
        if audioMixInputParams.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixInputParams
            audioMix = mix
        }

        return PreviewComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: duration,
            outputSize: outputSize
        )
    }

    // MARK: - Per-track population

    private struct VideoTrackResult {
        let trackID: CMPersistentTrackID
        let firstNaturalSize: CGSize
    }

    /// Adds one composition video track for the given Pixelbay track and
    /// inserts each clip's sourceRange slice at its timelineRange.start.
    /// Returns the trackID + the natural size of the FIRST clip's source —
    /// used by the screen track to inform output sizing. Phase 4 follow-
    /// up: per-clip natural size for clips with mixed-resolution sources.
    private static func populateVideoTrack(
        composition: AVMutableComposition,
        track: Track,
        project: Project,
        bundleURL: URL
    ) async throws -> VideoTrackResult {
        guard let mutableTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PreviewCompositionError.noVideoTrack(bundleURL)
        }
        var firstNaturalSize: CGSize = .zero
        var firstTransform: CGAffineTransform = .identity
        var inserted = false
        for clip in track.clips {
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { continue }
            let url = bundleURL.appendingPathComponent(asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PreviewCompositionError.fileNotFound(url)
            }
            let assetObj = AVURLAsset(url: url)
            let videoTracks = try await assetObj.loadTracks(withMediaType: .video)
            guard let sourceTrack = videoTracks.first else {
                throw PreviewCompositionError.noVideoTrack(url)
            }
            let sourceRange = CMTimeRange(
                start: cmTime(clip.sourceRange.start),
                duration: cmTime(clip.sourceRange.duration)
            )
            let timelineStart = cmTime(clip.timelineRange.start)
            let timelineDuration = cmTime(clip.timelineRange.duration)
            try mutableTrack.insertTimeRange(sourceRange, of: sourceTrack, at: timelineStart)
            // Per-clip speed: when timelineRange.duration ≠ sourceRange.duration
            // (i.e., clip.speed ≠ 1.0), retime the just-inserted segment
            // to match the timeline duration. Skipped when equal so the
            // tolerance for normal-speed clips stays exact.
            if CMTimeCompare(sourceRange.duration, timelineDuration) != 0 && timelineDuration > .zero {
                mutableTrack.scaleTimeRange(
                    CMTimeRange(start: timelineStart, duration: sourceRange.duration),
                    toDuration: timelineDuration
                )
            }
            if !inserted {
                firstNaturalSize = try await sourceTrack.load(.naturalSize)
                firstTransform = try await sourceTrack.load(.preferredTransform)
                inserted = true
            }
        }
        if inserted {
            mutableTrack.preferredTransform = firstTransform
        }
        return VideoTrackResult(trackID: mutableTrack.trackID, firstNaturalSize: firstNaturalSize)
    }

    /// Same shape for audio. Returns the audio-mix input parameters with
    /// per-clip volume ramps, or nil if no clips inserted.
    private static func populateAudioTrack(
        composition: AVMutableComposition,
        track: Track,
        project: Project,
        bundleURL: URL
    ) async throws -> AVMutableAudioMixInputParameters? {
        guard let mutableTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        var inserted = false
        let inputParams = AVMutableAudioMixInputParameters(track: mutableTrack)
        for clip in track.clips {
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { continue }
            let url = bundleURL.appendingPathComponent(asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let assetObj = AVURLAsset(url: url)
            let audioTracks = try await assetObj.loadTracks(withMediaType: .audio)
            guard let sourceTrack = audioTracks.first else { continue }
            let sourceRange = CMTimeRange(
                start: cmTime(clip.sourceRange.start),
                duration: cmTime(clip.sourceRange.duration)
            )
            let timelineStart = cmTime(clip.timelineRange.start)
            try mutableTrack.insertTimeRange(sourceRange, of: sourceTrack, at: timelineStart)
            // Per-clip volume → ramp segment over the clip's timeline
            // range. setVolumeRamp with start == end gives a flat-volume
            // segment. Multiple non-overlapping segments compose into the
            // full audio mix for that track.
            let timelineRange = CMTimeRange(
                start: timelineStart,
                duration: cmTime(clip.timelineRange.duration)
            )
            inputParams.setVolumeRamp(
                fromStartVolume: Float(max(0, clip.volume)),
                toEndVolume: Float(max(0, clip.volume)),
                timeRange: timelineRange
            )
            inserted = true
        }
        guard inserted else { return nil }
        return inputParams
    }

    // MARK: - Helpers

    /// Replace each `.zoom` keyframe's stored `trajectory` slice with a
    /// fresh slice taken from the (smoothed) master cursor trajectory
    /// against the keyframe's CURRENT timeline range. This is what makes
    /// "drag the right edge to extend" actually extend cursor-follow —
    /// the slice baked in at generate-time only covers the original
    /// range, so without re-slicing the evaluator clamps to the last
    /// stored sample for the extended portion.
    ///
    /// No-op (returns input unchanged) when `cursorTrajectory` is nil or
    /// empty. Non-zoom keyframes pass through untouched. When a re-slice
    /// produces an empty result (no samples fall in the new range) the
    /// keyframe's trajectory is cleared to nil so the evaluator falls
    /// back to the static (centerX, centerY) instead of locking to a
    /// stale single sample.
    // Exposed `internal` (no `private`) so `ApplyCursorTrajectoryTests` can
    // exercise the pinned-skip contract without going through the full
    // AVMutableComposition build path. The helper is still a static, no-state
    // utility — only the access level changed. Lives on
    // `PreviewCompositionBuilder` (the enum), not on `PreviewComposition`
    // (the value type returned by build).
    static func applyCursorTrajectory(
        to effects: [EffectKeyframe],
        cursorTrajectory: [MouseTrajectorySample]?
    ) -> [EffectKeyframe] {
        guard let master = cursorTrajectory, !master.isEmpty else {
            return effects
        }
        let smoothed = MouseTrajectory.smoothed(master)
        return effects.map { kf -> EffectKeyframe in
            guard kf.kind == .zoom else { return kf }
            // Pinned keyframes opt out of trajectory re-slicing. Without this,
            // gesture-sourced marks (shake / circle) silently re-acquire
            // cursor-tracking at every composition build — the editor command
            // sets trajectory: nil, but this pass would otherwise overwrite
            // it with a fresh windowed slice of the master cursor path,
            // re-enabling the jitter the pinned mode exists to prevent.
            if kf.anchorMode == .pinned { return kf }
            let slice = MouseTrajectory.window(smoothed, timelineRange: kf.timelineRange)
            var next = kf
            next.trajectory = slice.isEmpty ? nil : slice
            return next
        }
    }

    private static func computeOutputSize(from screenSize: CGSize) -> CGSize {
        let maxWidth = defaultOutputSize.width
        let maxHeight = defaultOutputSize.height
        guard screenSize.width > 0, screenSize.height > 0 else {
            return defaultOutputSize
        }
        let widthScale = maxWidth / screenSize.width
        let heightScale = maxHeight / screenSize.height
        let scale = min(1, min(widthScale, heightScale))
        let scaled = CGSize(
            width: floor(screenSize.width * scale),
            height: floor(screenSize.height * scale)
        )
        return CGSize(
            width: max(2, floor(scaled.width / 2) * 2),
            height: max(2, floor(scaled.height / 2) * 2)
        )
    }

    private static func cmTime(_ rt: RationalTime) -> CMTime {
        CMTime(value: rt.value, timescale: rt.timescale)
    }

    private static func makeVideoComposition(
        duration: CMTime,
        outputSize: CGSize,
        layoutPreset: LayoutPreset,
        effects: [EffectKeyframe],
        screenTrackID: CMPersistentTrackID,
        webcamTrackID: CMPersistentTrackID?,
        cursorSprite: CursorSpriteData?,
        cursorSettings: CursorSettings?,
        cursorTrajectory: [MouseTrajectorySample]
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.customVideoCompositorClass = PixelbayVideoCompositor.self

        var layerMapping: [CMPersistentTrackID: LayerKind] = [screenTrackID: .screen]
        if let webcamTrackID {
            layerMapping[webcamTrackID] = .webcam
        }
        let layout = LayoutCalculator.resolve(
            preset: layoutPreset,
            outputSize: outputSize,
            hasWebcam: webcamTrackID != nil
        )
        let instruction = PixelbayCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            layout: layout,
            layerMapping: layerMapping,
            effects: effects,
            cursorSprite: cursorSprite,
            cursorSettings: cursorSettings,
            cursorTrajectory: cursorTrajectory
        )
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

#endif
