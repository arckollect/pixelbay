import Foundation
import PixelbayCore

// All of the inputs CaptureSession needs to start a recording, gathered into
// a single Sendable value. The session computes this from its constructor
// arguments and hands it to the backend; tests construct one directly to
// drive the state machine.
public struct CapturePlan: Sendable, Equatable {
    public var sessionID: String
    public var source: CaptureSource
    // Optional cam: identified by AVCaptureDevice.uniqueID. The live backend
    // resolves to an AVCaptureDevice at start time.
    public var camera: String?
    public var audio: AudioSource
    public var includeSystemAudio: Bool
    public var bundleURL: URL
    public var outputs: CaptureOutputs
    // Bundle identifiers whose windows should be excluded from the screen
    // capture. The live backend resolves them via SCShareableContent's
    // applications list and passes the matches to SCContentFilter's
    // excludingApplications. Used by §4.10 to keep Pixelbay's own picker /
    // recording HUD out of screen.mov.
    public var excludedBundleIdentifiers: [String]

    public init(
        sessionID: String,
        source: CaptureSource,
        camera: String?,
        audio: AudioSource,
        includeSystemAudio: Bool,
        bundleURL: URL,
        outputs: CaptureOutputs,
        excludedBundleIdentifiers: [String] = []
    ) {
        self.sessionID = sessionID
        self.source = source
        self.camera = camera
        self.audio = audio
        self.includeSystemAudio = includeSystemAudio
        self.bundleURL = bundleURL
        self.outputs = outputs
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }
}
