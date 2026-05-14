import Foundation
import PixelbayCore

// CaptureSession is the actor-owned state machine for a single recording. It
// owns no framework objects directly — those live behind a CaptureBackend
// (live impl: ScreenCaptureKit + AVFoundation; test impl: programmable fake)
// so the state-machine logic is testable without spawning real SCStreams.
//
// Lifecycle:
//
//   .idle ─start()─▶ .preparing ─backend.start resolves─▶ .recording
//                                                              │
//                                                              ├─ stop() ─▶ .stopping ─▶ .stopped(summary)
//                                                              │
//                                                              └─ backend errors ─▶ .failed(error)
//
// The session is single-use: once it reaches a terminal state, the caller
// constructs a fresh CaptureSession for the next recording.
//
// **Permissions are NOT preflighted here.** Per HANDOFF §4.5, the app layer
// gates start() on `PermissionCoordinator.statuses[.screenRecording] ==
// .granted`. If the user revoked screen-recording between the gate and
// start, SCStream returns `notAllowed` which the live backend translates to
// `CaptureError.notPermitted` — the session just propagates it.
public actor CaptureSession {
    public private(set) var state: CaptureState = .idle
    public let plan: CapturePlan
    private let backend: any CaptureBackend
    private var errorMonitor: Task<Void, Never>?

    public init(plan: CapturePlan, backend: any CaptureBackend) {
        self.plan = plan
        self.backend = backend
    }

    // Begin recording. Transitions .idle → .preparing → .recording on success;
    // .preparing → .failed on backend setup failure (and rethrows). Throws
    // CaptureError.invalidState if the session is not idle.
    public func start() async throws {
        guard state == .idle else {
            throw CaptureError.invalidState(message: "start() called from \(state)")
        }
        state = .preparing
        do {
            let captureStart = try await backend.start(plan: plan)
            state = .recording
            startErrorMonitor()
            // captureStart is held by the backend; it'll surface in the
            // CaptureSummary when stop() resolves. Keeping the value out of
            // the session's own state matches the rule that the backend is
            // the source of truth for runtime timing.
            _ = captureStart
        } catch let error as CaptureError {
            state = .failed(error: error)
            throw error
        } catch {
            let wrapped = CaptureError.streamFailed(message: error.localizedDescription)
            state = .failed(error: wrapped)
            throw wrapped
        }
    }

    // Stop recording. Transitions .recording → .stopping → .stopped(summary)
    // on success; .stopping → .failed on flush failure. Throws if called
    // before start() reached .recording.
    @discardableResult
    public func stop() async throws -> CaptureSummary {
        guard state == .recording else {
            throw CaptureError.invalidState(message: "stop() called from \(state)")
        }
        state = .stopping
        errorMonitor?.cancel()
        errorMonitor = nil
        do {
            let summary = try await backend.stop()
            state = .stopped(summary: summary)
            return summary
        } catch let error as CaptureError {
            state = .failed(error: error)
            throw error
        } catch {
            let wrapped = CaptureError.streamFailed(message: error.localizedDescription)
            state = .failed(error: wrapped)
            throw wrapped
        }
    }

    private func startErrorMonitor() {
        // Task spawned without an explicit isolation annotation inherits the
        // enclosing actor's isolation — the `for await` loop runs on this
        // actor, so handleBackendError is a same-actor call and needs no
        // await. Suspension at the `await` on backend.errors releases the
        // actor between iterations, so stop() and cancellation aren't blocked.
        errorMonitor = Task { [backend] in
            for await error in backend.errors {
                self.handleBackendError(error)
                return
            }
        }
    }

    // Single-shot transition into .failed when the backend reports a mid-
    // recording error. Called from the error-monitor task; subsequent
    // backend errors are ignored because the session is already terminal.
    private func handleBackendError(_ error: CaptureError) {
        guard !state.isTerminal else { return }
        state = .failed(error: error)
    }
}

// File-path derivation for a session's output URLs. Pulled out of the actor
// init so tests can exercise it directly without constructing a backend.
//
// Convention (per HANDOFF §2.4):
//   bundle/media/screen-<sessionID>.mov       always present
//   bundle/media/cam-<sessionID>.mov          only when a camera is selected
//   bundle/media/mic-<sessionID>.caf          only when audio != .none
//   bundle/media/sysaudio-<sessionID>.caf     only when system audio is on
//
// `sessionID` should be a short, filename-safe token (UUID first 8 hex chars
// is the convention used by CaptureSession's convenience init). System audio
// is its own .caf file as of iter 10 (was a 2nd track in screen.mov pre-iter-10
// — see CaptureOutputs comment).
public enum CaptureOutputDeriver {
    public static func outputs(
        in bundle: ProjectBundle,
        sessionID: String,
        includeCam: Bool,
        includeMic: Bool,
        includeSysAudio: Bool = false
    ) -> CaptureOutputs {
        let media = bundle.mediaDirectoryURL
        return CaptureOutputs(
            screenURL: media.appendingPathComponent("screen-\(sessionID).mov"),
            camURL: includeCam ? media.appendingPathComponent("cam-\(sessionID).mov") : nil,
            micURL: includeMic ? media.appendingPathComponent("mic-\(sessionID).caf") : nil,
            sysAudioURL: includeSysAudio ? media.appendingPathComponent("sysaudio-\(sessionID).caf") : nil
        )
    }

    // Short filename-safe id: UUID's first 8 hex chars. Globally unique
    // enough for files coexisting in a single bundle; brevity matters when
    // the user opens the bundle in Finder.
    public static func makeSessionID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

extension CaptureSession {
    // Convenience init for the typical app-layer call site: pass the high-
    // level pieces (source, devices, bundle), and the session derives the
    // CapturePlan internally.
    //
    // sessionID defaults to a fresh short UUID; pass an explicit value when
    // you need deterministic file names (tests, debugging, restoring an
    // interrupted recording).
    public init(
        source: CaptureSource,
        cameraDeviceUniqueID: String?,
        audio: AudioSource,
        includeSystemAudio: Bool,
        bundle: ProjectBundle,
        backend: any CaptureBackend,
        sessionID: String = CaptureOutputDeriver.makeSessionID(),
        excludedBundleIdentifiers: [String] = []
    ) {
        let outputs = CaptureOutputDeriver.outputs(
            in: bundle,
            sessionID: sessionID,
            includeCam: cameraDeviceUniqueID != nil,
            includeMic: audio != .none,
            includeSysAudio: includeSystemAudio
        )
        let plan = CapturePlan(
            sessionID: sessionID,
            source: source,
            camera: cameraDeviceUniqueID,
            audio: audio,
            includeSystemAudio: includeSystemAudio,
            bundleURL: bundle.url,
            outputs: outputs,
            excludedBundleIdentifiers: excludedBundleIdentifiers
        )
        self.init(plan: plan, backend: backend)
    }
}
