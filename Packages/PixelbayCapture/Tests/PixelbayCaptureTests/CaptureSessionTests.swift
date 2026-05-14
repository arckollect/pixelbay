import XCTest
import PixelbayCore
@testable import PixelbayCapture

final class CaptureSessionTests: XCTestCase {
    // MARK: - state machine

    func test_initialState_isIdle() async {
        let session = CaptureSession(plan: .stub(), backend: FakeCaptureBackend())
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func test_start_transitionsIdleToRecording_onSuccess() async throws {
        let backend = FakeCaptureBackend(
            startOutcome: .succeed(captureStart: .seconds(2))
        )
        let session = CaptureSession(plan: .stub(), backend: backend)

        try await session.start()

        let state = await session.state
        XCTAssertEqual(state, .recording)
        let starts = await backend.startCount
        XCTAssertEqual(starts, 1)
    }

    func test_start_setsFailedState_onBackendError() async {
        let backend = FakeCaptureBackend(startOutcome: .fail(.notPermitted))
        let session = CaptureSession(plan: .stub(), backend: backend)

        await assertThrows(CaptureError.notPermitted) {
            try await session.start()
        }

        let state = await session.state
        XCTAssertEqual(state, .failed(error: .notPermitted))
    }

    func test_start_throwsInvalidState_whenAlreadyRecording() async throws {
        let session = CaptureSession(plan: .stub(), backend: FakeCaptureBackend())
        try await session.start()

        do {
            try await session.start()
            XCTFail("Expected invalidState")
        } catch let CaptureError.invalidState(message) {
            XCTAssertTrue(message.contains("recording"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        // State remains recording — failed second start does not derail it.
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    func test_stop_transitionsRecordingToStopped_onSuccess() async throws {
        let summary = CaptureSummary.empty
        let backend = FakeCaptureBackend(stopOutcome: .succeed(summary))
        let session = CaptureSession(plan: .stub(), backend: backend)
        try await session.start()

        let result = try await session.stop()

        XCTAssertEqual(result, summary)
        let state = await session.state
        XCTAssertEqual(state, .stopped(summary: summary))
        let stops = await backend.stopCount
        XCTAssertEqual(stops, 1)
    }

    func test_stop_throwsInvalidState_whenIdle() async {
        let session = CaptureSession(plan: .stub(), backend: FakeCaptureBackend())

        do {
            _ = try await session.stop()
            XCTFail("Expected invalidState")
        } catch let CaptureError.invalidState(message) {
            XCTAssertTrue(message.contains("idle"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_stop_setsFailedState_onBackendError() async throws {
        let backend = FakeCaptureBackend(
            stopOutcome: .fail(.streamFailed(message: "writer flush failed"))
        )
        let session = CaptureSession(plan: .stub(), backend: backend)
        try await session.start()

        await assertThrows(CaptureError.streamFailed(message: "writer flush failed")) {
            _ = try await session.stop()
        }

        let state = await session.state
        XCTAssertEqual(state, .failed(error: .streamFailed(message: "writer flush failed")))
    }

    func test_midRecordingError_transitionsToFailed() async throws {
        let backendError = CaptureError.streamFailed(message: "window closed")
        let backend = FakeCaptureBackend(pendingErrors: [backendError])
        let session = CaptureSession(plan: .stub(), backend: backend)

        try await session.start()

        // The error monitor fires asynchronously; poll briefly.
        let observed = await waitForState(of: session) { state in
            if case .failed = state { return true } else { return false }
        }
        XCTAssertEqual(observed, .failed(error: backendError))
    }

    func test_postFailure_stopIsRejectedAsInvalidState() async throws {
        let backend = FakeCaptureBackend(
            pendingErrors: [.streamFailed(message: "boom")]
        )
        let session = CaptureSession(plan: .stub(), backend: backend)
        try await session.start()
        _ = await waitForState(of: session) { state in
            if case .failed = state { return true } else { return false }
        }

        do {
            _ = try await session.stop()
            XCTFail("Expected invalidState")
        } catch CaptureError.invalidState {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - output derivation

    func test_outputDeriver_includesCamAndMic_whenSelected() {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/Project.pixelbay"))
        let outputs = CaptureOutputDeriver.outputs(
            in: bundle,
            sessionID: "abc12345",
            includeCam: true,
            includeMic: true
        )

        XCTAssertEqual(outputs.screenURL.lastPathComponent, "screen-abc12345.mov")
        XCTAssertEqual(outputs.camURL?.lastPathComponent, "cam-abc12345.mov")
        XCTAssertEqual(outputs.micURL?.lastPathComponent, "mic-abc12345.caf")

        // Each URL is rooted at the bundle's media directory.
        XCTAssertTrue(outputs.screenURL.path.contains("/Project.pixelbay/media/"))
        XCTAssertTrue(outputs.camURL!.path.contains("/Project.pixelbay/media/"))
        XCTAssertTrue(outputs.micURL!.path.contains("/Project.pixelbay/media/"))
    }

    func test_outputDeriver_excludesCam_whenCameraNotSelected() {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/X.pixelbay"))
        let outputs = CaptureOutputDeriver.outputs(
            in: bundle, sessionID: "id", includeCam: false, includeMic: true
        )
        XCTAssertNil(outputs.camURL)
        XCTAssertNotNil(outputs.micURL)
    }

    func test_outputDeriver_excludesMic_whenAudioNone() {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/Y.pixelbay"))
        let outputs = CaptureOutputDeriver.outputs(
            in: bundle, sessionID: "id", includeCam: true, includeMic: false
        )
        XCTAssertNotNil(outputs.camURL)
        XCTAssertNil(outputs.micURL)
    }

    func test_makeSessionID_isShortFilenameSafe() {
        let id1 = CaptureOutputDeriver.makeSessionID()
        let id2 = CaptureOutputDeriver.makeSessionID()
        XCTAssertEqual(id1.count, 8)
        XCTAssertNotEqual(id1, id2)
        // Lowercase hex only — safe for both filesystems and URL paths.
        XCTAssertTrue(id1.allSatisfy { $0.isHexDigit && $0.isLowercase || $0.isNumber })
    }

    // MARK: - convenience init

    func test_convenienceInit_buildsPlan_fromHighLevelArgs() async {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/Z.pixelbay"))
        let session = CaptureSession(
            source: .display(displayID: 1),
            cameraDeviceUniqueID: "cam-uid",
            audio: .external(deviceUniqueID: "mic-uid"),
            includeSystemAudio: true,
            bundle: bundle,
            backend: FakeCaptureBackend(),
            sessionID: "deadbeef"
        )

        let plan = await session.plan
        XCTAssertEqual(plan.sessionID, "deadbeef")
        XCTAssertEqual(plan.source, .display(displayID: 1))
        XCTAssertEqual(plan.camera, "cam-uid")
        XCTAssertEqual(plan.audio, .external(deviceUniqueID: "mic-uid"))
        XCTAssertTrue(plan.includeSystemAudio)
        XCTAssertEqual(plan.bundleURL, bundle.url)
        XCTAssertEqual(plan.outputs.screenURL.lastPathComponent, "screen-deadbeef.mov")
        XCTAssertEqual(plan.outputs.camURL?.lastPathComponent, "cam-deadbeef.mov")
        XCTAssertEqual(plan.outputs.micURL?.lastPathComponent, "mic-deadbeef.caf")
    }

    func test_convenienceInit_omitsCamAndMic_whenAudioNone() async {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/Z.pixelbay"))
        let session = CaptureSession(
            source: .display(displayID: 1),
            cameraDeviceUniqueID: nil,
            audio: .none,
            includeSystemAudio: false,
            bundle: bundle,
            backend: FakeCaptureBackend(),
            sessionID: "abcdef01"
        )

        let plan = await session.plan
        XCTAssertNil(plan.camera)
        XCTAssertNil(plan.outputs.camURL)
        XCTAssertNil(plan.outputs.micURL)
        XCTAssertNotNil(plan.outputs.screenURL)
    }

    // MARK: - helpers

    private func assertThrows(_ expected: CaptureError, _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected to throw \(expected)")
        } catch let e as CaptureError {
            XCTAssertEqual(e, expected)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // Polls the actor's state with a short backoff. Used for asynchronously-
    // observed transitions (mid-recording errors arrive via a Task).
    private func waitForState(
        of session: CaptureSession,
        timeout: TimeInterval = 1.0,
        until predicate: @Sendable (CaptureState) -> Bool
    ) async -> CaptureState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await session.state
            if predicate(current) { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await session.state
    }
}

extension CapturePlan {
    static func stub(sessionID: String = "stub0001") -> CapturePlan {
        CapturePlan(
            sessionID: sessionID,
            source: .display(displayID: 1),
            camera: nil,
            audio: .none,
            includeSystemAudio: false,
            bundleURL: URL(fileURLWithPath: "/tmp/stub.pixelbay"),
            outputs: CaptureOutputs(
                screenURL: URL(fileURLWithPath: "/tmp/stub.pixelbay/media/screen-\(sessionID).mov"),
                camURL: nil,
                micURL: nil
            )
        )
    }
}
