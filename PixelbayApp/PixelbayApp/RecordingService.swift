import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog
import Observation
import PixelbayCapture
import PixelbayCore
import PixelbayInputCapture
import PixelbayRecording
import ScreenCaptureKit

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "RecordingService")

// Shared session owner driven by §4.10's pre-capture picker, recording HUD,
// menubar, and global hotkeys. One instance lives at app scope (created in
// PixelbayAppApp); every UI surface reads `phase` via @Observable and calls
// start(plan:) / stop() against this same actor-of-MainActor.
//
// Replaces SmokeRecorderModel's role of owning the CaptureSession +
// AssetWriterPipeline. The smoke harness's bundle layout, MediaAsset write
// pattern, and human-readable error mapping live here too — that code was
// validated through 14 §4.5b iterations and shouldn't be re-derived.
@MainActor
@Observable
final class RecordingService {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case stopping
        case stopped(Result)
        case failed(message: String)
    }

    struct Result: Equatable {
        var bundleURL: URL
        var screenURL: URL
        var camURL: URL?
        var micURL: URL?
        var sysAudioURL: URL?
        var durationSeconds: Double
        var screenDurationSeconds: Double?
        var camDurationSeconds: Double?
        var micDurationSeconds: Double?
        var sysAudioDurationSeconds: Double?
        var markerStillExists: Bool
        var trackStats: [CaptureTrack: TrackStats]
        var writerErrors: [String]
        /// Phase 5 — IDs of every `MediaAsset` this recording appended to
        /// `project.assets`. Single-recording callers can ignore this
        /// (assets are already wired into tracks); Scenes mode reads it to
        /// build a `Take` whose `assetIDs` point at the freshly recorded
        /// media without having to diff `project.assets` before/after.
        var assetIDs: [MediaAssetID] = []
        /// Session ID prefix used by every file this recording produced
        /// (`screen-{sessionID}.mov`, `clicks-{sessionID}.json`, etc.).
        /// Phase 5 stamps it onto `Take.sessionID`; single-recording mode
        /// ignores it (the value is also embedded in each asset's relativePath).
        var sessionID: String = ""
    }

    struct StartRequest {
        var displayID: CGDirectDisplayID
        /// Recorded display's **bounds in global points** (`SCDisplay.frame`).
        /// Plumbed through to `ClickLogger` so x/y land in normalised [0…1]
        /// coordinates in the sidecar — the origin is essential for secondary
        /// displays whose global coords are negative or offset (positioning a
        /// secondary display to the left of / above the main one), where
        /// dividing by size alone would collapse every event's x or y to 0.
        /// Optional for tests / synthetic StartRequest construction.
        var displayPointsBounds: CGRect?
        var cameraID: String?
        var micID: String?
        var includeSystemAudio: Bool
        var logClicks: Bool
        /// Phase 5 — when false, the captured `MediaAsset`s are still
        /// appended to `project.assets` but NO `Track`s are created. Scenes
        /// mode passes `false` so the per-scene takes don't pollute the
        /// timeline with N tracks per recording; the merge step (see
        /// `ScenesMerger`) creates the shared screen/webcam/mic/sysAudio
        /// tracks once at the end. Default `true` preserves Phase 1–4
        /// single-recording behavior unchanged.
        var appendTracks: Bool = true
    }

    var phase: Phase = .idle

    private var session: CaptureSession?
    private var pipeline: AssetWriterPipeline?
    private var bundle: ProjectBundle?
    private var clickLogger: ClickLogger?
    private var clickSessionID: String?
    /// Same 8-char prefix used by every file this recording produces (screen,
    /// cam, mic, sysAudio, clicks sidecar). Captured at `start(_:existingBundle:)`
    /// time so `stop()` can stamp it onto the `Result` for scenes mode
    /// (which builds a `Take` whose `sessionID` matches the file naming).
    private var currentSessionID: String?
    /// Captured at `start(_:existingBundle:)` time so `stop()` knows whether
    /// to wire each recorded asset into a `Track` (single-recording mode,
    /// default) or only append it to `project.assets` (scenes mode). Resets
    /// to true in `tearDown()`.
    private var appendTracksOnStop: Bool = true
    /// The last self-allocating `StartRequest` (nil for scenes-mode recordings
    /// that record into an existing bundle). `restart()` re-issues it to begin
    /// a fresh take with identical settings after discarding the current one.
    private var lastRequest: StartRequest?
    /// False while recording into a caller-supplied bundle (scenes mode) — the
    /// bundle is shared across takes, so Discard/Restart must not delete it.
    private var ownsBundle = true
    /// Non-nil while recording a scene ("Scene N"); drives the HUD to show the
    /// label and hide Discard/Restart. nil for normal single recordings.
    private(set) var sceneLabel: String?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Bundle URLs owned by an in-flight recording (set from `prepareBundle()`
    /// / `start(existingBundle:)` until `tearDown()` clears it on stop or
    /// failure). Orphan recovery consults this so it NEVER flags or discards
    /// the live bundle as an interrupted recording — the
    /// `media/.recording-in-progress` marker that orphan detection keys on is
    /// *expected* while recording, and deleting the bundle mid-recording
    /// destroys the capture (project.json vanishes → stop() throws
    /// ProjectBundleError). See OrphanRecoveryModel.
    var activeBundleURLs: Set<URL> {
        guard let bundle else { return [] }
        return [bundle.url]
    }

    var canStartRecording: Bool {
        switch phase {
        case .idle, .stopped, .failed: return true
        default: return false
        }
    }

    /// Phase 5 — pass `existingBundle` to record into a persistent
    /// scenes-session bundle instead of allocating a fresh one. The default
    /// `nil` preserves Phase 1–4 single-recording behavior (one bundle per
    /// recording at `~/Library/Application Support/Pixelbay/Recordings/rec-*`).
    func start(_ request: StartRequest, existingBundle: ProjectBundle? = nil, sceneLabel: String? = nil) async {
        guard canStartRecording else {
            log.notice("start() ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        phase = .preparing
        appendTracksOnStop = request.appendTracks
        // Remember the request so Restart can re-issue an identical take after
        // discarding the current one (the HUD doesn't hold the StartRequest).
        // Scenes mode passes an existingBundle, which Restart wouldn't have —
        // only remember requests that allocate their own bundle.
        lastRequest = existingBundle == nil ? request : nil
        // Scenes mode records into a SHARED persistent bundle (existingBundle):
        // we don't own it, so Discard/Restart (which delete the bundle) must be
        // refused — they'd wipe every other take. The HUD also hides those
        // buttons in scenes mode; `sceneLabel` non-nil is the scenes-mode flag
        // the HUD reads to show "Scene N" and drop Discard/Restart.
        self.ownsBundle = (existingBundle == nil)
        self.sceneLabel = sceneLabel
        do {
            let bundle = try existingBundle ?? prepareBundle()
            let audio: AudioSource = request.micID.map { .external(deviceUniqueID: $0) } ?? .none
            let sessionID = CaptureOutputDeriver.makeSessionID()
            self.currentSessionID = sessionID
            let outputs = CaptureOutputDeriver.outputs(
                in: bundle,
                sessionID: sessionID,
                includeCam: request.cameraID != nil,
                includeMic: audio != .none,
                includeSysAudio: request.includeSystemAudio
            )
            // Exclude Pixelbay's own windows (picker, HUD, post-capture)
            // from screen.mov. Without this the recording HUD bakes into
            // screen.mov, per HANDOFF §4.10.
            let bundleID = Bundle.main.bundleIdentifier.map { [$0] } ?? []
            let plan = CapturePlan(
                sessionID: sessionID,
                source: .display(displayID: request.displayID),
                camera: request.cameraID,
                audio: audio,
                includeSystemAudio: request.includeSystemAudio,
                bundleURL: bundle.url,
                outputs: outputs,
                excludedBundleIdentifiers: bundleID
            )
            let pipeline = try AssetWriterPipeline(plan: plan)
            let backend = LiveCaptureBackend(sink: pipeline)
            let session = CaptureSession(plan: plan, backend: backend)
            self.bundle = bundle
            self.pipeline = pipeline
            self.session = session
            try await session.start()
            // Click logger is best-effort and per-recording opt-in. A
            // failure here (Accessibility not granted, tap creation refused)
            // does NOT fail the recording — we just skip the sidecar.
            if request.logClicks {
                // Default gesture detectors are enabled when click logging
                // is on: drawing a small circle (slice #11.e) OR rapidly
                // shaking the cursor (slice #11.g, "shake to find cursor"
                // muscle-memory) mid-recording logs a ZoomMark, same effect
                // as the ⌃⌘Z hotkey but without reaching for the keyboard.
                // Defaults are tuned conservatively (circle: ≤30% residual /
                // ≥270° sweep; shake: ≥4 axis reversals / 4-25% screen amp /
                // 0.4s window) so accidental motion doesn't trigger zooms;
                // both share a 1s cooldown after firing.
                let logger = ClickLogger(
                    displayPointsBounds: request.displayPointsBounds,
                    gestureDetector: CircleGestureDetector(),
                    shakeDetector: ShakeGestureDetector()
                )
                do {
                    try await logger.start()
                    self.clickLogger = logger
                    self.clickSessionID = sessionID
                    log.info("click logger started for sessionID=\(sessionID, privacy: .public)")
                } catch {
                    log.error("click logger start failed (continuing without): \(String(describing: error), privacy: .public)")
                }
            }
            phase = .recording(startedAt: Date())
            log.info("recording started bundle=\(bundle.url.path, privacy: .public)")
        } catch {
            log.error("start() failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: humanReadable(error))
            tearDown()
        }
    }

    func stop() async {
        guard case .recording = phase, let session, let bundle else { return }
        phase = .stopping
        do {
            let summary = try await session.stop()
            // Stop the click logger BEFORE writing project.json so the
            // sidecar lands alongside the media files in the same atomic
            // step (from the user's perspective). The logger itself is
            // crash-safe — partial sidecars never leak because writes are
            // atomic temp+rename.
            if let logger = clickLogger, let sessionID = clickSessionID {
                let recording = await logger.stop()
                writeClicksSidecar(
                    clicks: recording.clicks,
                    moves: recording.moves,
                    marks: recording.marks,
                    sessionID: sessionID,
                    captureStart: summary.captureStart.seconds,
                    bundle: bundle
                )
            }
            let result = try writeProjectAndReport(summary: summary, bundle: bundle)
            phase = .stopped(result)
            log.info("recording stopped duration=\(result.durationSeconds, format: .fixed(precision: 2)) writerErrors=\(result.writerErrors.count)")
        } catch {
            log.error("stop() failed: \(String(describing: error), privacy: .public)")
            phase = .failed(message: humanReadable(error))
        }
        tearDown()
    }

    private func writeClicksSidecar(
        clicks: [ClickEvent],
        moves: [MouseMove],
        marks: [ZoomMark],
        sessionID: String,
        captureStart: Double,
        bundle: ProjectBundle
    ) {
        let url = bundle.mediaDirectoryURL
            .appendingPathComponent(ClicksSidecarStore.filename(for: sessionID))
        let sidecar = ClicksSidecar(
            sessionID: sessionID,
            captureStart: captureStart,
            events: clicks,
            moves: moves,
            marks: marks
        )
        do {
            try ClicksSidecarStore.write(sidecar, to: url)
            log.info("clicks sidecar written clicks=\(clicks.count) moves=\(moves.count) marks=\(marks.count) url=\(url.path, privacy: .public)")
        } catch {
            log.error("clicks sidecar write failed (recording itself is fine): \(String(describing: error), privacy: .public)")
        }
    }

    /// Log a user-stated zoom anchor at the current cursor position. Wired
    /// up by `AppState.bindHotkeys` (⌃⌘Z by default). Silently no-ops when
    /// the recording isn't live or the click logger wasn't started for this
    /// session — the logger normalises coords against `displayPointsBounds`
    /// on its way in, so the sidecar receives values in `[0…1]`.
    func markZoomAtCursor() async {
        guard case .recording = phase, let logger = clickLogger else { return }
        guard let event = CGEvent(source: nil) else { return }
        // Same timestamp + coord conventions ClickEventSource uses.
        let timestamp = Double(event.timestamp) / 1_000_000_000.0
        let location = event.location
        await logger.recordMark(at: timestamp, x: Double(location.x), y: Double(location.y))
        log.info("zoom mark logged at (\(location.x, format: .fixed(precision: 1)), \(location.y, format: .fixed(precision: 1)))")
    }

    func acknowledgeResult() {
        guard canStartRecording else { return }
        phase = .idle
    }

    /// Throw away the in-flight recording: stop capture, drop the click sidecar,
    /// delete the whole `.pixelbay` bundle, and return to `.idle` (the launcher
    /// reopens on the picker). Unlike `stop()`, produces no `Result` and leaves
    /// nothing on disk.
    func discard() async {
        guard case .recording = phase, ownsBundle else { return }
        await teardownAndDeleteBundle()
        phase = .idle
        log.info("recording discarded")
    }

    /// Discard the current take and immediately begin a fresh one with the same
    /// settings. Stays in recording-adjacent phases throughout (no trip through
    /// `.idle`), so the launcher never flashes back in between takes.
    func restart() async {
        guard case .recording = phase, ownsBundle else { return }
        let request = lastRequest
        await teardownAndDeleteBundle()
        guard let request else {
            // No re-issuable request (e.g. scenes mode) — fall back to idle.
            phase = .idle
            log.notice("restart() had no stored request — discarded only")
            return
        }
        log.info("restarting recording")
        await start(request)
    }

    /// Shared cleanup for `discard()`/`restart()`: finalize the writers (so file
    /// handles release cleanly), drop the click logger's recording without
    /// writing a sidecar, tear down session state, and delete the bundle
    /// directory — which also removes the `.recording-in-progress` marker so
    /// OrphanRecovery won't later flag it. Leaves `phase == .stopping`; the
    /// caller sets the next phase.
    private func teardownAndDeleteBundle() async {
        phase = .stopping
        let bundleURL = bundle?.url
        // Finalize then delete: simpler and safe versus cancelling writers
        // mid-flight (which the capture API doesn't expose). The summary is
        // discarded.
        if let session {
            _ = try? await session.stop()
        }
        if let logger = clickLogger {
            _ = await logger.stop()
        }
        tearDown()
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }
    }

    // MARK: - Helpers

    private func prepareBundle() throws -> ProjectBundle {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Pixelbay/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let stamp = RecordingService.filenameTimestamp.string(from: Date())
        let bundleURL = appSupport.appendingPathComponent("rec-\(stamp).pixelbay")
        let store = ProjectBundleStore()
        let project = Project(name: "Recording \(stamp)")
        return try store.createBundle(at: bundleURL, project: project)
    }

    private func writeProjectAndReport(
        summary: CaptureSummary,
        bundle: ProjectBundle
    ) throws -> Result {
        let store = ProjectBundleStore()
        var project = try store.loadProject(from: bundle)

        // Each captured file becomes a MediaAsset that goes into project.assets.
        // In single-recording mode (`appendTracksOnStop == true`) we ALSO
        // create one Track per asset holding a single clip — Phase 1
        // behavior, preserved verbatim so PreviewCompositionBuilder /
        // ProjectView see a previewable timeline immediately after stop.
        // In scenes mode (`appendTracksOnStop == false`) we skip the track
        // creation: the scenes session model wraps the returned assetIDs in
        // a `Take`, and `ScenesMerger` builds shared tracks at merge time.
        var capturedAssetIDs: [MediaAssetID] = []

        // Canonical recording length for the timeline. Tracks where the
        // camera / mic / sysAudio writer started later than the screen (or
        // stopped earlier) produce shorter files than the screen, but the
        // user thinks of the recording as one wall-clock interval and
        // expects every enabled track to span that full interval on the
        // timeline. Use screenDuration when present (the most reliable
        // signal — SCStream rarely warms up late); fall back to the
        // wall-clock duration; fall back to the longest per-track duration
        // for audio-only edge cases. PreviewComposition pads short sources
        // with empty time (silence for audio, transparent for video) so a
        // 3 s cam clip on a 10 s screen plays cam for 3 s then drops out,
        // rather than appearing as a 3 s nub the user has to drag-extend
        // by hand only to discover the file ends after 3 s of playback.
        let canonicalDuration = pickCanonicalRecordingDuration(summary: summary)

        var screenAsset = MediaAsset(
            kind: .display,
            relativePath: relativePath(of: summary.outputs.screenURL, in: bundle),
            captureStart: summary.captureStart,
            nativeDuration: summary.screenDuration ?? .zero
        )
        // Phase 3c — flag every new screen recording as synthetic-cursor
        // ready. LiveCaptureBackend hard-codes
        // `SCStreamConfiguration.showsCursor = false`, so the OS cursor is
        // NOT baked into the recorded frames. The compositor checks this
        // flag before drawing the synthetic cursor pass; legacy assets
        // (saved before this change) don't carry the flag, so they keep
        // their baked-in OS cursor and the compositor skips the pass for
        // them.
        screenAsset.cursorRenderedSynthetically = true
        project.assets.append(screenAsset)
        capturedAssetIDs.append(screenAsset.id)
        if appendTracksOnStop {
            appendTrack(for: screenAsset, name: "Screen", kind: .screen, timelineDuration: canonicalDuration, into: &project)
        }

        if let camURL = summary.outputs.camURL {
            let camAsset = MediaAsset(
                kind: .webcam,
                relativePath: relativePath(of: camURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: summary.camDuration ?? .zero
            )
            project.assets.append(camAsset)
            capturedAssetIDs.append(camAsset.id)
            if appendTracksOnStop {
                appendTrack(for: camAsset, name: "Webcam", kind: .webcam, timelineDuration: canonicalDuration, into: &project)
            }
        }
        // Only persist a mic asset when the writer actually produced audio.
        // A nil `micDuration` means the mic writer never produced usable
        // output (e.g. AAC `startWriting` rejected the device format with
        // -11861, leaving a 0-byte mic-*.caf). Persisting it anyway puts a
        // damaged asset into the project that the editor then fails to load
        // a waveform for on every refresh. The writer failure is surfaced
        // separately via `summary.writerErrors` → PostCaptureView. Scene-2's
        // short-but-valid 0.117s capture has a positive duration and is kept.
        if let micURL = summary.outputs.micURL,
           let micDuration = summary.micDuration,
           micDuration.seconds > 0 {
            let micAsset = MediaAsset(
                kind: .microphone,
                relativePath: relativePath(of: micURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: micDuration
            )
            project.assets.append(micAsset)
            capturedAssetIDs.append(micAsset.id)
            if appendTracksOnStop {
                appendTrack(for: micAsset, name: "Microphone", kind: .microphone, timelineDuration: canonicalDuration, into: &project)
            }
        } else if summary.outputs.micURL != nil {
            log.notice("skipping mic asset: writer produced no usable audio (micDuration=\(summary.micDuration?.seconds ?? -1))")
        }
        if let sysURL = summary.outputs.sysAudioURL {
            let sysAsset = MediaAsset(
                kind: .systemAudio,
                relativePath: relativePath(of: sysURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: summary.sysAudioDuration ?? .zero
            )
            project.assets.append(sysAsset)
            capturedAssetIDs.append(sysAsset.id)
            if appendTracksOnStop {
                appendTrack(for: sysAsset, name: "System Audio", kind: .systemAudio, timelineDuration: canonicalDuration, into: &project)
            }
        }
        try store.writeProject(project, to: bundle)

        let markerURL = bundle.mediaDirectoryURL
            .appendingPathComponent(AssetWriterPipeline.recordingMarkerFilename)
        return Result(
            bundleURL: bundle.url,
            screenURL: summary.outputs.screenURL,
            camURL: summary.outputs.camURL,
            micURL: summary.outputs.micURL,
            sysAudioURL: summary.outputs.sysAudioURL,
            durationSeconds: summary.duration.seconds,
            screenDurationSeconds: summary.screenDuration?.seconds,
            camDurationSeconds: summary.camDuration?.seconds,
            micDurationSeconds: summary.micDuration?.seconds,
            sysAudioDurationSeconds: summary.sysAudioDuration?.seconds,
            markerStillExists: FileManager.default.fileExists(atPath: markerURL.path),
            trackStats: summary.trackStats,
            writerErrors: summary.writerErrors,
            assetIDs: capturedAssetIDs,
            sessionID: currentSessionID ?? ""
        )
    }

    /// Append a Track to the project containing a single Clip whose
    /// `sourceRange` covers the full underlying asset (`[0, nativeDuration)`)
    /// AND whose `timelineRange` spans the canonical recording length
    /// (`timelineDuration`, normally the screen's wall-clock duration).
    /// Skipped if the asset itself has zero duration — that means the
    /// writer never finalized any samples for this track (writer error
    /// or no input ever arrived), and an empty clip would just trip up
    /// PreviewCompositionBuilder with a zero-range insertTimeRange.
    ///
    /// Why the two ranges can differ: when the cam / mic / sysAudio
    /// pipeline starts later than SCStream (camera warm-up takes ~ a
    /// second; audio drivers similar), the underlying file is shorter
    /// than the screen recording. Without this padding the timeline
    /// would show the cam clip as a 3 s nub on a 10 s screen, and
    /// dragging its edge would extend `timelineRange` past `sourceRange`
    /// with no underlying content — the preview would just go blank
    /// after 3 s. Now the timeline clip claims the full 10 s up front,
    /// and `PreviewCompositionBuilder.populateVideoTrack` /
    /// `populateAudioTrack` insert the available source at
    /// `timelineRange.start` and leave the tail empty (silence for
    /// audio, transparent for video) when
    /// `sourceRange.duration < timelineRange.duration && clip.speed == 1.0`.
    /// `clip.speed` stays 1.0 — this is padding, NOT a speed change.
    ///
    /// Per-track captureStart drift handling (placing the cam clip a
    /// few hundred ms later when its first sample landed late, so the
    /// content is positioned in real time rather than the start of the
    /// clip) is a Phase-4 concern — typical drift is too small to read
    /// as a visible offset on playback, and the user-visible benefit
    /// of "all enabled tracks span the whole recording" is what people
    /// actually notice.
    private func appendTrack(
        for asset: MediaAsset,
        name: String,
        kind: TrackKind,
        timelineDuration: RationalTime,
        into project: inout Project
    ) {
        guard asset.nativeDuration.value > 0 else {
            log.notice("appendTrack skipped — \(name, privacy: .public) has zero duration")
            return
        }
        let sourceRange = TimeRange(start: .zero, duration: asset.nativeDuration)
        // Use the larger of canonical-timeline-duration and this asset's
        // own duration so a single short audio-only recording (where the
        // mic somehow outlasts the screen — rare but possible if SCStream
        // dropped its last second) doesn't get its tail truncated.
        let timelineDur: RationalTime = {
            if asset.nativeDuration.seconds > timelineDuration.seconds {
                return asset.nativeDuration
            }
            return timelineDuration
        }()
        let timelineRange = TimeRange(start: .zero, duration: timelineDur)
        let clip = Clip(
            assetID: asset.id,
            sourceRange: sourceRange,
            timelineRange: timelineRange
        )
        project.tracks.append(Track(kind: kind, name: name, clips: [clip]))
    }

    /// Pick the canonical "recording length" for the timeline. Prefer the
    /// screen recording's duration because SCStream rarely warms up late;
    /// fall back to the wall-clock duration from start() to stop(); fall
    /// back to the longest per-track duration for audio-only edge cases.
    private func pickCanonicalRecordingDuration(summary: CaptureSummary) -> RationalTime {
        if let screen = summary.screenDuration, screen.seconds > 0 {
            return screen
        }
        if summary.duration.seconds > 0 {
            return summary.duration
        }
        let perTrack = [summary.camDuration, summary.micDuration, summary.sysAudioDuration]
            .compactMap { $0?.seconds }
        if let longest = perTrack.max(), longest > 0 {
            return .seconds(longest)
        }
        return .zero
    }

    private func relativePath(of url: URL, in bundle: ProjectBundle) -> String {
        let bundlePath = bundle.url.standardizedFileURL.path
        let abs = url.standardizedFileURL.path
        if abs.hasPrefix(bundlePath + "/") {
            return String(abs.dropFirst(bundlePath.count + 1))
        }
        return abs
    }

    private func tearDown() {
        session = nil
        pipeline = nil
        bundle = nil
        // Release the process-wide `ClickEventSource.live`'s CGEvent
        // tap BEFORE nullifying our logger reference. Without this, a
        // recording that failed AFTER click logger started but BEFORE
        // stop()'s success path ran (e.g. AVCaptureSession stream
        // failure → stop() throws → catch runs tearDown) left
        // `LiveTapStorage.port` set, and every subsequent recording
        // in this process aborted its click logger with
        // `ClickEventSourceError.alreadyRunning`. The visible
        // symptoms downstream: no clicks sidecar → auto-zoom and
        // gesture buttons greyed in the editor, no synthetic cursor
        // in preview, manual zoom anchors to the screen centre
        // instead of the last cursor position. `ClickEventSource.live.stop`
        // is idempotent (LiveTapStorage.stop nil-guards `port`) so
        // this is safe even on the success path where the logger's
        // own stop already cleared the tap.
        if clickLogger != nil {
            ClickEventSource.live.stop()
        }
        clickLogger = nil
        clickSessionID = nil
        currentSessionID = nil
        appendTracksOnStop = true
        ownsBundle = true
        sceneLabel = nil
    }

    private func humanReadable(_ error: Error) -> String {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .invalidState(let m): return "Invalid state: \(m)"
            case .notPermitted: return "Screen recording was denied. Re-grant in System Settings, then relaunch."
            case .sourceUnavailable(let m): return "Source unavailable: \(m)"
            case .bundleUnavailable(let m): return "Bundle unavailable: \(m)"
            case .streamFailed(let m): return "Stream failed: \(m)"
            }
        }
        return error.localizedDescription
    }

    nonisolated static let filenameTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
