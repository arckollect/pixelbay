import Foundation

// File URLs the recording pipeline writes during a capture session.
//
// Each session writes to up-to-four separate files (per HANDOFF §2.4 — track
// ungrouping in Phase 2 and parallel-stream window-swap in Phase 4 both rely
// on these being independent). System audio is its own .caf file alongside
// screen.mov as of iter 10 — the earlier "second track inside screen.mov"
// shape kept failing AVAssetWriter dual-track encoding while the equivalent
// single-track writers (cam.mov, mic.caf) recorded cleanly with the same
// codec settings, so the cheapest fix was to make screen.mov single-track-
// video too.
public struct CaptureOutputs: Sendable, Equatable, Hashable {
    public var screenURL: URL
    public var camURL: URL?
    public var micURL: URL?
    public var sysAudioURL: URL?

    public init(screenURL: URL, camURL: URL?, micURL: URL?, sysAudioURL: URL? = nil) {
        self.screenURL = screenURL
        self.camURL = camURL
        self.micURL = micURL
        self.sysAudioURL = sysAudioURL
    }
}
