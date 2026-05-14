import Foundation
import PixelbayCore
@testable import PixelbayCapture

// Programmable test double for CaptureBackend. Each test configures the
// canned outcomes (capture-start time, summary, error sequence), then drives
// CaptureSession through start/stop and asserts on resulting state.
//
// Mirrors the Sendable-shim pattern from PixelbayPermissions tests, but as
// an actor because the backend is conceptually stateful (start sets up,
// stop tears down) and we need to observe call-counts safely from the
// outside.
actor FakeCaptureBackend: CaptureBackend {
    enum StartOutcome: Sendable {
        case succeed(captureStart: RationalTime)
        case fail(CaptureError)
    }

    enum StopOutcome: Sendable {
        case succeed(CaptureSummary)
        case fail(CaptureError)
    }

    private let startOutcome: StartOutcome
    private let stopOutcome: StopOutcome
    private let pendingErrors: [CaptureError]

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let errorContinuation: AsyncStream<CaptureError>.Continuation
    nonisolated let errors: AsyncStream<CaptureError>

    init(
        startOutcome: StartOutcome = .succeed(captureStart: RationalTime.seconds(0)),
        stopOutcome: StopOutcome = .succeed(.empty),
        pendingErrors: [CaptureError] = []
    ) {
        self.startOutcome = startOutcome
        self.stopOutcome = stopOutcome
        self.pendingErrors = pendingErrors
        var continuation: AsyncStream<CaptureError>.Continuation!
        self.errors = AsyncStream { continuation = $0 }
        self.errorContinuation = continuation
    }

    func start(plan: CapturePlan) async throws -> RationalTime {
        startCount += 1
        switch startOutcome {
        case .succeed(let t):
            // Push any pending errors onto the stream so the session's
            // monitor task can pick them up after start resolves. The errors
            // are queued so iteration order is deterministic.
            for err in pendingErrors {
                errorContinuation.yield(err)
            }
            return t
        case .fail(let err):
            throw err
        }
    }

    func stop() async throws -> CaptureSummary {
        stopCount += 1
        errorContinuation.finish()
        switch stopOutcome {
        case .succeed(let s): return s
        case .fail(let err): throw err
        }
    }
}

extension RationalTime {
    static func seconds(_ v: Int64) -> RationalTime {
        RationalTime(value: v * 600, timescale: 600)
    }
}

extension CaptureSummary {
    static var empty: CaptureSummary {
        CaptureSummary(
            outputs: CaptureOutputs(screenURL: URL(fileURLWithPath: "/tmp/screen.mov"), camURL: nil, micURL: nil),
            captureStart: .seconds(0),
            duration: .seconds(1)
        )
    }
}
