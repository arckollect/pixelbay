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
// Output size is taken from the screen video's natural size, capped at the
// current high-quality export target.

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
    // Default high-quality output size. 1080p was visibly soft for Retina
    // screen recordings after the synthetic cursor/compositor pass, so the
    // edit/export path now keeps up to UHD detail when the source has it.
    public static let defaultOutputSize = CGSize(width: 3840, height: 2160)

    // Cap for the LIVE PREVIEW composition (export keeps `defaultOutputSize`).
    // The preview pane is ~1300 pt; compositing every frame at full UHD made
    // the GPU pay 4K-blur cost for pixels nobody sees (dropped frames during
    // fast cursor-follow pans read as "the follow is laggy") and quadrupled
    // the in-process destination-buffer pool. 1620p stays Retina-sharp at
    // editor pane sizes while cutting per-frame pixel cost ~44 %.
    public static let previewMaxOutputSize = CGSize(width: 2880, height: 1620)


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
        cursorClickTimes: [Double] = [],
        cursorSprite: CursorSpriteData? = nil,
        maxOutputSize: CGSize = PreviewCompositionBuilder.defaultOutputSize
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
        let outputSize = computeOutputSize(from: screenSize, cappedTo: maxOutputSize)
        let videoComposition = await buildVideoComposition(
            project: project,
            outputSize: outputSize,
            duration: duration,
            screenTrackID: screenTrackID,
            webcamTrackID: webcamTrackID,
            cursorTrajectory: cursorTrajectory,
            cursorClickTimes: cursorClickTimes,
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
        cursorClickTimes: [Double] = [],
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
        let cursorMaster: [MouseTrajectorySample]
        if let master = cursorTrajectory, !master.isEmpty {
            cursorMaster = master
        } else {
            cursorMaster = []
        }
        // Reference architecture: recording stores the raw cursor telemetry;
        // zoom follow resolves and smooths it at render time. Do not rewrite
        // the path up front with Pixelbay-specific path-taming knobs, or the
        // camera no longer feels like the OpenScreen reference.
        let effects = applyCursorTrajectory(
            to: project.effects,
            cursorTrajectory: cursorMaster.isEmpty ? nil : cursorMaster,
            tuning: project.tuning
        )
        // Phase 3c — only enable the synthetic cursor pass when the screen
        // asset was captured with `showsCursor = false`. Legacy recordings
        // have the OS cursor baked in, so drawing on top would double it.
        let cursorSyntheticallyRendered = project.assets.contains { asset in
            asset.kind == .display && asset.cursorRenderedSynthetically
        }
        let cursorTrajectoryForRender = cursorSyntheticallyRendered ? cursorMaster : []
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
            tuning: project.tuning,
            backgroundImage: backgroundImage
        )
    }

    /// Per-sample blend of the raw and smoothed cursor paths by the highest
    /// zoom-keyframe strength at that instant — the `.zoomsOnly` smoothing
    /// scope. Outside any zoom the cursor is the honest recording; the
    /// stylized path fades in/out with each zoom's ease windows so the
    /// switch is never visible as a jump.
    static func blendByZoomStrength(
        raw: [MouseTrajectorySample],
        smoothed: [MouseTrajectorySample],
        effects: [EffectKeyframe]
    ) -> [MouseTrajectorySample] {
        guard raw.count == smoothed.count else { return smoothed }
        let zooms = effects.filter { $0.kind == .zoom }
        guard !zooms.isEmpty else { return raw }
        return zip(raw, smoothed).map { rawSample, smoothSample in
            let strength = zooms.reduce(0.0) { acc, kf in
                max(acc, kf.strength(at: rawSample.timelineTime))
            }
            guard strength > 0 else { return rawSample }
            return MouseTrajectorySample(
                timelineTime: rawSample.timelineTime,
                centerX: rawSample.centerX + (smoothSample.centerX - rawSample.centerX) * strength,
                centerY: rawSample.centerY + (smoothSample.centerY - rawSample.centerY) * strength
            )
        }
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
            let timelineDuration = cmTime(clip.timelineRange.duration)
            try mutableTrack.insertTimeRange(sourceRange, of: sourceTrack, at: timelineStart)
            if timelineDuration > .zero
                && CMTimeCompare(sourceRange.duration, timelineDuration) != 0
                && clip.speed != 1.0
            {
                mutableTrack.scaleTimeRange(
                    CMTimeRange(start: timelineStart, duration: sourceRange.duration),
                    toDuration: timelineDuration
                )
            }
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
                duration: timelineDuration
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
    /// fresh slice taken from the raw master cursor trajectory
    /// against the keyframe's CURRENT timeline range. This is what makes
    /// "drag the right edge to extend" actually extend cursor-follow —
    /// the slice baked in at generate-time only covers the original
    /// range, so without re-slicing the evaluator clamps to the last
    /// stored sample for the extended portion.
    ///
    /// `buildVideoComposition()` passes the raw recorded cursor telemetry
    /// here. The cursor-follow keyframe receives a keyframe-local slice, and
    /// the reference adaptive-follow layer smooths that target in content
    /// time before the compositor spring smooths the final camera transform.
    ///
    /// **Camera follow.** After windowing each cursor-follow keyframe's
    /// slice, it is routed through `MouseTrajectory.adaptiveFollow` — the
    /// reference distance-adaptive, frame-rate-independent cursor-follow
    /// layer. Preview and export both build through this same composition
    /// path, so they share `ZoomMotionConstants.autoFollowParams`.
    ///
    /// Pinned (gesture) keyframes still short-circuit before this stage —
    /// they want a locked anchor, not a slack follow.
    ///
    /// The follow parameters are the shared OpenScreen constants in
    /// `ZoomMotionConstants`, so preview and export do not diverge.
    ///
    /// Non-zoom and pinned keyframes pass through untouched. When
    /// `cursorTrajectory` is nil or empty, cursor-follow zooms keep their
    /// existing trajectory state. When a re-slice produces an empty result
    /// (no samples fall in the new range) the keyframe's trajectory is
    /// cleared to nil so the evaluator falls back to the static
    /// (centerX, centerY) instead of locking to a stale single sample.
    // Exposed `internal` (no `private`) so `ApplyCursorTrajectoryTests` can
    // exercise the pinned-skip contract without going through the full
    // AVMutableComposition build path. The helper is still a static, no-state
    // utility — only the access level changed. Lives on
    // `PreviewCompositionBuilder` (the enum), not on `PreviewComposition`
    // (the value type returned by build).
    static func applyCursorTrajectory(
        to effects: [EffectKeyframe],
        cursorTrajectory: [MouseTrajectorySample]?,
        tuning: TuningSettings = .default
    ) -> [EffectKeyframe] {
        return effects.map { kf -> EffectKeyframe in
            guard kf.kind == .zoom else { return kf }
            // Pinned keyframes opt out of trajectory re-slicing. Without this,
            // gesture-sourced marks (shake / circle) silently re-acquire
            // cursor-tracking at every composition build — the editor command
            // sets trajectory: nil, but this pass would otherwise overwrite
            // it with a fresh windowed slice of the master cursor path,
            // re-enabling the jitter the pinned mode exists to prevent.
            if kf.anchorMode == .pinned { return kf }
            var next = kf
            guard let master = cursorTrajectory, !master.isEmpty else {
                return next
            }
            let windowed = MouseTrajectory.window(
                master,
                timelineRange: kf.timelineRange,
                leadSeconds: kf.followLeadSeconds
            )
            guard !windowed.isEmpty else {
                next.trajectory = nil
                return next
            }
            if kf.anchorMode == .centerCursor {
                next.trajectory = windowed
                return next
            }
            let followed = MouseTrajectory.adaptiveFollow(
                windowed,
                params: ZoomMotionConstants.autoFollowParams
            )
            next.trajectory = followed
            return next
        }
    }

    private static func computeOutputSize(
        from screenSize: CGSize,
        cappedTo maxSize: CGSize = PreviewCompositionBuilder.defaultOutputSize
    ) -> CGSize {
        let maxWidth = maxSize.width
        let maxHeight = maxSize.height
        guard screenSize.width > 0, screenSize.height > 0 else {
            return maxSize
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
        tuning: TuningSettings,
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
            tuning: tuning,
            backgroundImage: backgroundImage
        )
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

#endif
