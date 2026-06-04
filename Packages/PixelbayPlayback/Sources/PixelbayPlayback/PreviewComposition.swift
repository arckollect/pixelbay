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
    // The composition's video track IDs, retained so a *presentation-only*
    // edit (layout / background / effects / cursor) can rebuild just the
    // videoComposition against the SAME composition — no new AVPlayerItem.
    public var screenTrackID: CMPersistentTrackID
    public var webcamTrackID: CMPersistentTrackID?

    public init(
        composition: AVComposition,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        duration: CMTime,
        outputSize: CGSize,
        screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        webcamTrackID: CMPersistentTrackID? = nil
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.outputSize = outputSize
        self.screenTrackID = screenTrackID
        self.webcamTrackID = webcamTrackID
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
        wallpaperImageProvider: WallpaperImageProvider? = nil,
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
        let videoComposition = await buildVideoComposition(
            project: project,
            outputSize: outputSize,
            duration: duration,
            screenTrackID: screenTrackID,
            webcamTrackID: webcamTrackID,
            cursorTrajectory: cursorTrajectory,
            cursorSprite: cursorSprite,
            wallpaperSource: wallpaperSource,
            wallpaperImageProvider: wallpaperImageProvider
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
            outputSize: outputSize,
            screenTrackID: screenTrackID,
            webcamTrackID: webcamTrackID
        )
    }

    /// Build *only* the videoComposition (layout / background / effects /
    /// cursor) for a project, against pre-existing composition track IDs. This
    /// is the presentation half of `build`, factored out so a layout-only edit
    /// can rebuild it in place against the SAME `AVComposition` — no track
    /// re-insertion, no new `AVPlayerItem`, no decoder churn. `nonisolated
    /// async` so the (potentially heavy) wallpaper-image decode runs off the
    /// main actor.
    public static func buildVideoComposition(
        project: Project,
        outputSize: CGSize,
        duration: CMTime,
        screenTrackID: CMPersistentTrackID,
        webcamTrackID: CMPersistentTrackID?,
        cursorTrajectory: [MouseTrajectorySample]?,
        cursorSprite: CursorSpriteData?,
        wallpaperSource: WallpaperSource?,
        wallpaperImageProvider: WallpaperImageProvider?
    ) async -> AVMutableVideoComposition {
        await Task.yield()  // hop off the caller's actor before the image decode
        let resolvedPreset = wallpaperSource?.resolve(project.layout) ?? project.layout
        // Image wallpaper: decode + aspect-crop once so the per-frame
        // compositor just blits a cached texture. Nil for every other bg kind.
        let backgroundImage: CGImage?
        if case .image(let ref) = resolvedPreset.background {
            backgroundImage = wallpaperImageProvider?.provide(ref, outputSize)
        } else {
            backgroundImage = nil
        }
        // Phase 3d iteration 2 — sprite and anchor share the SAME upstream
        // smoothing (`spriteSmoothed`, τ≈0.02 EMA), so the only cursor-vs-camera
        // lag is `anchorFollow`'s spring (τRelaxed=0.05 / safeZone=0.30).
        let spriteMaster: [MouseTrajectorySample]
        if let master = cursorTrajectory, !master.isEmpty {
            spriteMaster = MouseTrajectory.spriteSmoothed(master)
        } else {
            spriteMaster = []
        }
        let effects = applyCursorTrajectory(
            to: project.effects,
            cursorTrajectory: spriteMaster.isEmpty ? nil : spriteMaster
        )
        // Phase 3c — only enable the synthetic cursor pass when the screen
        // asset was captured with `showsCursor = false`. Legacy recordings
        // have the OS cursor baked in, so drawing on top would double it.
        let cursorSyntheticallyRendered = project.assets.contains { asset in
            asset.kind == .display && asset.cursorRenderedSynthetically
        }
        let cursorTrajectoryForRender: [MouseTrajectorySample] =
            cursorSyntheticallyRendered ? spriteMaster : []
        return makeVideoComposition(
            duration: duration,
            outputSize: outputSize,
            layoutPreset: resolvedPreset,
            effects: effects,
            screenTrackID: screenTrackID,
            webcamTrackID: webcamTrackID,
            cursorSprite: cursorSyntheticallyRendered ? cursorSprite : nil,
            cursorSettings: cursorSyntheticallyRendered ? project.cursorSettings : nil,
            cursorTrajectory: cursorTrajectoryForRender,
            backgroundImage: backgroundImage
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
            // Per-clip speed vs pad-with-empty disambiguation. When the
            // source and timeline durations disagree there are two valid
            // intents (speed change, or recording with a shorter file
            // than the canonical timeline length). We use `clip.speed`
            // to decide:
            //
            //   speed != 1.0 → user explicitly set a playback speed via
            //     SetClipSpeedCommand; retime the inserted segment to
            //     fill `timelineDuration`. This is the Phase 2 behavior.
            //
            //   speed == 1.0 → the recording pipeline produced a file
            //     shorter than the canonical timeline length (cam / mic
            //     / sysAudio writer warmed up late, or stopped early).
            //     RecordingService.appendTrack pads `timelineRange.duration`
            //     to the screen's wall-clock length so the timeline UI
            //     shows the full recording, and we let
            //     `insertTimeRange` write the available source at
            //     `timelineStart`; the residual `[sourceEnd, timelineEnd]`
            //     stays empty (transparent on a video track, silence on
            //     audio). The playback experience: cam plays normally
            //     for as long as it has frames, then drops out to a
            //     transparent PiP. No re-scaling / no slowdown.
            if timelineDuration > .zero
                && CMTimeCompare(sourceRange.duration, timelineDuration) != 0
                && clip.speed != 1.0
            {
                mutableTrack.scaleTimeRange(
                    CMTimeRange(start: timelineStart, duration: sourceRange.duration),
                    toDuration: timelineDuration
                )
            }
            // speed == 1.0 + duration mismatch → pad case. We intentionally
            // do NOT scaleTimeRange; the empty tail past
            // `timelineStart + sourceRange.duration` renders transparent in
            // the AVMutableComposition, which is exactly what we want for
            // a cam clip whose underlying file is shorter than the screen
            // recording.
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
        // Defensive: AVMutableScheduledAudioParameters throws
        // NSInvalidArgumentException ("The timeRange of a ramp must not
        // overlap the timeRange of an existing ramp") if two clips on
        // the same track produce overlapping volume ramps. Pre-fix
        // scenes-merged projects on disk are known to violate this when
        // the underlying mic / sysAudio files were longer than the
        // screen recording. Track the previous ramp's end and clamp /
        // skip the current ramp if it would overlap, rather than
        // crashing the entire load.
        var previousRampEnd: CMTime?
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
            inserted = true
            // A muted track plays silent regardless of per-clip volume — a
            // single flat 0 volume is applied below (after the loop), so we
            // skip per-clip ramps entirely here. This also avoids the
            // overlap-skip leak: a ramp that's skipped for overlap would
            // otherwise mix at the default 1.0 volume, so muted clips in an
            // overlap region could still bleed audio.
            if track.muted { continue }
            // Per-clip volume → ramp segment over the clip's timeline
            // range. setVolumeRamp with start == end gives a flat-volume
            // segment. Multiple non-overlapping segments compose into the
            // full audio mix for that track.
            var rampRange = CMTimeRange(
                start: timelineStart,
                duration: cmTime(clip.timelineRange.duration)
            )
            if let prevEnd = previousRampEnd, CMTimeCompare(rampRange.start, prevEnd) < 0 {
                let clampedStart = prevEnd
                let originalEnd = CMTimeRangeGetEnd(rampRange)
                if CMTimeCompare(clampedStart, originalEnd) >= 0 {
                    // Entire ramp falls inside the previous one; skip
                    // setting a ramp for this clip. The underlying
                    // audio still mixes at the track's default volume,
                    // so playback isn't silent — we just lose the
                    // per-clip volume control for the overlap region.
                    log.notice("populateAudioTrack: clip ramp [\(rampRange.start.seconds), \(originalEnd.seconds)] fully overlaps previous ramp ending at \(prevEnd.seconds); skipping ramp")
                    continue
                }
                rampRange = CMTimeRange(
                    start: clampedStart,
                    duration: CMTimeSubtract(originalEnd, clampedStart)
                )
            }
            inputParams.setVolumeRamp(
                fromStartVolume: Float(max(0, clip.volume)),
                toEndVolume: Float(max(0, clip.volume)),
                timeRange: rampRange
            )
            previousRampEnd = CMTimeRangeGetEnd(rampRange)
        }
        guard inserted else { return nil }
        // Muted track → one flat 0 volume across the whole track. Done once
        // here (not per-clip) so it never overlaps a ramp's time range.
        if track.muted {
            inputParams.setVolume(0, at: .zero)
        }
        return inputParams
    }

    // MARK: - Helpers

    /// Replace each `.zoom` keyframe's stored `trajectory` slice with a
    /// fresh slice taken from the (pre-smoothed) master cursor trajectory
    /// against the keyframe's CURRENT timeline range. This is what makes
    /// "drag the right edge to extend" actually extend cursor-follow —
    /// the slice baked in at generate-time only covers the original
    /// range, so without re-slicing the evaluator clamps to the last
    /// stored sample for the extended portion.
    ///
    /// **Input is assumed pre-smoothed by the caller.** `build()` runs
    /// `MouseTrajectory.spriteSmoothed` (τ≈0.02 EMA) once for both the
    /// cursor-sprite render path AND the anchor path. This helper only
    /// touches the anchor path — it receives the spriteSmoothed output as
    /// `cursorTrajectory` and produces per-keyframe trajectory slices for
    /// `EffectEvaluator.zoomCenter` to consume.
    ///
    /// **Anchor follows via continuous soft spring (Phase 3d iter 2).** After
    /// windowing each cursor-follow keyframe's slice, the slice is routed
    /// through `MouseTrajectory.anchorFollow` with NO deadzone, 30 % safe
    /// zone, and NO lookahead. Spring τ ramps from `tauRelaxed = 0.05 s`
    /// near viewport centre to `tauTight = 0.04 s` near the safe-zone wall.
    /// Sharing `spriteSmoothed` between sprite and anchor (instead of the
    /// earlier `cameraDamped`/`spriteSmoothed` split) means the only
    /// cursor-to-camera lag is the spring itself — at v=0.2 norm/s the
    /// steady-state lag is ≈ 0.02 norm-units, well inside the 0.075 safe-
    /// zone half-width, so the hard clamp almost never bites.
    ///
    /// Pinned (gesture) keyframes still short-circuit before this stage —
    /// they want a locked anchor, not a deadzone follow.
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
        return effects.map { kf -> EffectKeyframe in
            guard kf.kind == .zoom else { return kf }
            // Pinned keyframes opt out of trajectory re-slicing. Without this,
            // gesture-sourced marks (shake / circle) silently re-acquire
            // cursor-tracking at every composition build — the editor command
            // sets trajectory: nil, but this pass would otherwise overwrite
            // it with a fresh windowed slice of the master cursor path,
            // re-enabling the jitter the pinned mode exists to prevent.
            if kf.anchorMode == .pinned { return kf }
            let windowed = MouseTrajectory.window(
                master,
                timelineRange: kf.timelineRange,
                leadSeconds: kf.followLeadSeconds
            )
            guard !windowed.isEmpty else {
                var next = kf
                next.trajectory = nil
                return next
            }
            // Phase 3d — anchor follows via the tightened continuous soft
            // spring with NO lookahead. The 3c per-sample decel confidence
            // is no longer plumbed because the lookahead it gated is gone;
            // the spring's tight tauRelaxed (0.08 s) catches up on its own
            // and predicting forward was making cursor lead worse, not
            // better.
            let followed = MouseTrajectory.anchorFollow(
                windowed,
                zoomFactor: kf.zoomFactor,
                deadzoneFraction: 0.0,
                lookaheadSeconds: 0.0
            )
            var next = kf
            next.trajectory = followed
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
        cursorTrajectory: [MouseTrajectorySample],
        backgroundImage: CGImage?
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
            cursorTrajectory: cursorTrajectory,
            backgroundImage: backgroundImage
        )
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

#endif
