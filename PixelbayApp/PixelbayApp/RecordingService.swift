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
    }

    var phase: Phase = .idle

    private var session: CaptureSession?
    private var pipeline: AssetWriterPipeline?
    private var bundle: ProjectBundle?
    private var clickLogger: ClickLogger?
    private var clickSessionID: String?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var canStartRecording: Bool {
        switch phase {
        case .idle, .stopped, .failed: return true
        default: return false
        }
    }

    func start(_ request: StartRequest) async {
        guard canStartRecording else {
            log.notice("start() ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        phase = .preparing
        do {
            let bundle = try prepareBundle()
            let audio: AudioSource = request.micID.map { .external(deviceUniqueID: $0) } ?? .none
            let sessionID = CaptureOutputDeriver.makeSessionID()
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

        // Each captured file becomes a MediaAsset AND a Track holding a
        // single Clip that covers the whole asset on the timeline.
        // PreviewCompositionBuilder iterates project.tracks (not assets), so
        // skipping the track here means a recording can be saved but never
        // previewed or exported. Phase 2 onwards mutates these tracks via
        // EditCommands; Phase 1 just plumbs them in 1:1 with the assets.
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
        appendTrack(for: screenAsset, name: "Screen", kind: .screen, into: &project)

        if let camURL = summary.outputs.camURL {
            let camAsset = MediaAsset(
                kind: .webcam,
                relativePath: relativePath(of: camURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: summary.camDuration ?? .zero
            )
            project.assets.append(camAsset)
            appendTrack(for: camAsset, name: "Webcam", kind: .webcam, into: &project)
        }
        if let micURL = summary.outputs.micURL {
            let micAsset = MediaAsset(
                kind: .microphone,
                relativePath: relativePath(of: micURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: summary.micDuration ?? .zero
            )
            project.assets.append(micAsset)
            appendTrack(for: micAsset, name: "Microphone", kind: .microphone, into: &project)
        }
        if let sysURL = summary.outputs.sysAudioURL {
            let sysAsset = MediaAsset(
                kind: .systemAudio,
                relativePath: relativePath(of: sysURL, in: bundle),
                captureStart: summary.captureStart,
                nativeDuration: summary.sysAudioDuration ?? .zero
            )
            project.assets.append(sysAsset)
            appendTrack(for: sysAsset, name: "System Audio", kind: .systemAudio, into: &project)
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
            writerErrors: summary.writerErrors
        )
    }

    /// Append a Track to the project containing a single Clip that covers
    /// the full asset (sourceRange = timelineRange = [0, nativeDuration]).
    /// Skipped if the asset has zero duration — that means the writer never
    /// finalized any samples for this track (writer error or no input ever
    /// arrived), and an empty clip would just trip up PreviewCompositionBuilder
    /// with a zero-range insertTimeRange.
    ///
    /// All four track types (screen / webcam / microphone / systemAudio)
    /// share captureStart from the same CaptureSummary, so placing each
    /// track's clip at timelineRange.start = 0 keeps them in sync.
    /// Per-track captureStart drift handling is a Phase-4 concern (under
    /// long recordings + clock-domain crossings, the SCStream and
    /// AVCaptureSession bridges can land first samples ~tens of ms apart).
    private func appendTrack(
        for asset: MediaAsset,
        name: String,
        kind: TrackKind,
        into project: inout Project
    ) {
        guard asset.nativeDuration.value > 0 else {
            log.notice("appendTrack skipped — \(name, privacy: .public) has zero duration")
            return
        }
        let range = TimeRange(start: .zero, duration: asset.nativeDuration)
        let clip = Clip(
            assetID: asset.id,
            sourceRange: range,
            timelineRange: range
        )
        project.tracks.append(Track(kind: kind, name: name, clips: [clip]))
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
        clickLogger = nil
        clickSessionID = nil
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
