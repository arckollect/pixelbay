#if canImport(AVFoundation) && canImport(SwiftUI) && canImport(AppKit)
import AVFoundation
import AppKit
import Combine
import Foundation
import OSLog
import Observation
import PixelbayCompositor
import PixelbayCore
import QuartzCore
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "PreviewPlayer")

// SwiftUI-friendly AVPlayer wrapper for the post-capture preview surface.
// Owns the AVPlayer + AVPlayerItem + the PreviewComposition's
// AVMutableComposition / AVMutableVideoComposition. Phase 1's preview is
// play / pause / single-handle scrub — the timeline UI is Phase 2.
//
// Concurrency: lives on the main actor because AVPlayer mutates UI state.
// The PreviewComposition itself is constructed off-actor (it does file I/O
// for asset loading) and handed in via load(...).
@MainActor
@Observable
public final class PreviewPlayer {
    public enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    public private(set) var status: Status = .idle
    public private(set) var duration: CMTime = .zero
    public private(set) var currentTime: CMTime = .zero
    public private(set) var isPlaying: Bool = false

    private let player: AVPlayer
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    public init() {
        self.player = AVPlayer()
        self.player.allowsExternalPlayback = false
        self.player.actionAtItemEnd = .pause
    }

    // Explicit teardown for the periodic time observer + KVO + notification
    // observer. Call this from the view's `onDisappear`.
    //
    // We can't do this in deinit because @MainActor-isolated properties
    // aren't reachable from a nonisolated deinit in Swift 6. Holding the
    // observers in a separate nonisolated companion is the alternative; for
    // v0.1 a simple explicit dispose is cheaper.
    public func dispose() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        statusObservation = nil
        rateObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    public var underlyingPlayer: AVPlayer { player }

    public func load(
        project: Project,
        bundleURL: URL,
        wallpaperSource: WallpaperSource? = nil,
        cursorTrajectory: [MouseTrajectorySample]? = nil,
        cursorSprite: CursorSpriteData? = nil
    ) async {
        // Preserve playback continuity across reloads (Phase-2 edits
        // bump the document's revision counter; ProjectView re-keys the
        // .task per edit so this fires repeatedly during an editing
        // session). Without the save/restore the playhead resets to 0
        // and any in-progress play stops on every commit.
        let savedTime = currentTime
        let wasPlaying = isPlaying
        status = .loading
        do {
            let preview = try await PreviewCompositionBuilder.build(
                project: project,
                bundleURL: bundleURL,
                wallpaperSource: wallpaperSource,
                cursorTrajectory: cursorTrajectory,
                cursorSprite: cursorSprite
            )
            install(preview: preview)
            // Restore playhead within the new duration. If the new
            // duration is shorter than the previous time (user trimmed
            // the tail), clamp to the new duration.
            if duration > .zero {
                let clamped = CMTimeMinimum(savedTime, duration)
                if clamped > .zero {
                    seek(to: clamped)
                } else if !wasPlaying {
                    // Fresh load, paused at t=0. AVPlayer's initial pre-roll
                    // frame is composited before the webcam track's decoder is
                    // primed, so the camera PiP is missing until playback
                    // starts (the "first frame has no webcam" report). Nudge a
                    // seek to zero with a small toleranceAfter: AVFoundation
                    // settles every decoder, then re-pulls a frame through the
                    // compositor with all layers present. A few frames of
                    // tolerance is imperceptible but reliably dodges the
                    // camera's black warm-up frame too.
                    // Trailing completion closure selects the synchronous
                    // seek overload (the bare call resolves to the `async`
                    // variant in this async context and would need `await`).
                    player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600),
                        completionHandler: { _ in }
                    )
                }
            }
            if wasPlaying {
                play()
            }
            status = .ready
        } catch {
            log.error("PreviewPlayer load failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func play() {
        guard status == .ready else { return }
        if currentTime >= duration && duration > .zero {
            seek(to: .zero)
        }
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seek(to time: CMTime) {
        let clamped = CMTimeClampToRange(
            time,
            range: CMTimeRange(start: .zero, duration: duration)
        )
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    public func seekFraction(_ fraction: Double) {
        guard duration > .zero else { return }
        let secs = max(0, min(1, fraction)) * CMTimeGetSeconds(duration)
        seek(to: CMTime(seconds: secs, preferredTimescale: 600))
    }

    /// Jumps the playhead to the very start of the timeline.
    public func seekToStart() {
        seek(to: .zero)
    }

    /// Jumps the playhead to the end of the timeline.
    public func seekToEnd() {
        seek(to: duration)
    }

    /// Steps the playhead by `count` display frames (negative steps back).
    /// Pauses first — stepping while playing fights the play rate. Uses
    /// `AVPlayerItem.step(byCount:)` which moves by exact frame boundaries;
    /// falls back to a no-op when the item can't step in that direction
    /// (e.g. already at the head/tail). `currentTime` is re-read after so
    /// the UI updates immediately even while paused (the periodic observer
    /// won't tick on its own at rate 0).
    public func stepFrame(by count: Int) {
        guard status == .ready, count != 0, let item = player.currentItem else { return }
        if isPlaying { pause() }
        if count > 0, !item.canStepForward { return }
        if count < 0, !item.canStepBackward { return }
        item.step(byCount: count)
        currentTime = player.currentTime()
    }

    private func install(preview: PreviewComposition) {
        // Tear down any prior observation.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        rateObservation?.invalidate()

        let item = AVPlayerItem(asset: preview.composition)
        if let videoComposition = preview.videoComposition {
            item.videoComposition = videoComposition
        }
        if let audioMix = preview.audioMix {
            item.audioMix = audioMix
        }
        player.replaceCurrentItem(with: item)
        duration = preview.duration
        currentTime = .zero

        let interval = CMTime(value: 1, timescale: 30)
        // The closure runs on main queue per `queue: .main`, but Swift 6
        // doesn't infer @MainActor isolation from queue identity. We hop
        // explicitly so currentTime mutation is safe.
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }
}

// SwiftUI-hostable preview surface. Hosts an AVPlayerLayer directly inside
// a plain NSView rather than going through AVKit's AVPlayerView.
//
// We had been using AVPlayerView with controlsStyle = .none, but AVKit's
// internal AVPlayerController carries KVO on `currentItem.status` that
// races with rapid `replaceCurrentItem` swaps. Each Phase-2 edit bumps the
// project revision, which re-keys ProjectView's `.task` and reinstalls a
// fresh AVPlayerItem — the kind of churn AVPlayerController doesn't
// tolerate. Symptom: `NSInternalInconsistencyException: Cannot remove an
// observer ... for the key path "currentItem.status" from <AVPlayer>` fired
// from -[AVPlayerController dealloc] after a stale
// currentEnabledAssetTrackForMediaType: completion block crossed with an
// item swap.
//
// AVPlayerLayer doesn't run that observation machinery, so swapping items
// (or even the whole player) is safe.
public struct PreviewPlayerView: NSViewRepresentable {
    let player: PreviewPlayer
    let videoGravity: AVLayerVideoGravity

    /// `fill: false` (default) letterboxes the video to fit (`.resizeAspect`);
    /// `fill: true` crops it to fill the frame (`.resizeAspectFill`). Driven
    /// by the preview transport's fit/fill toggle.
    public init(player: PreviewPlayer, fill: Bool = false) {
        self.player = player
        self.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    public func makeNSView(context: Context) -> PlayerLayerHostingView {
        let view = PlayerLayerHostingView()
        view.attach(player: player.underlyingPlayer)
        view.setVideoGravity(videoGravity)
        return view
    }

    public func updateNSView(_ nsView: PlayerLayerHostingView, context: Context) {
        nsView.attach(player: player.underlyingPlayer)
        nsView.setVideoGravity(videoGravity)
    }
}

/// Layer-backed NSView whose backing CALayer is an AVPlayerLayer. Used by
/// PreviewPlayerView as a low-level replacement for AVPlayerView.
public final class PlayerLayerHostingView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    func attach(player: AVPlayer) {
        guard let playerLayer else { return }
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard let playerLayer, playerLayer.videoGravity != gravity else { return }
        playerLayer.videoGravity = gravity
    }
}
#endif
