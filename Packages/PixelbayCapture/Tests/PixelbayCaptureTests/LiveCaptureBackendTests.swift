#if canImport(ScreenCaptureKit) && canImport(AVFoundation)
import AVFoundation
import Foundation
import PixelbayCore
import ScreenCaptureKit
import XCTest
@testable import PixelbayCapture

// LiveCaptureBackend's full happy-path is exercised via the §4.5b manual
// smoke test (record into a real .pixelbay bundle, verify three files exist
// with sane durations) — automating that requires a real display, screen-
// recording permission, and a writable bundle, so it's not a unit test.
//
// What IS testable in unit tests, and lives here:
//   • CaptureSource cases that are not in v0.1 (.window / .area / .device)
//     short-circuit to .sourceUnavailable before any framework call.
//   • A ShareableContentLookup that throws is propagated unchanged.
//   • mapSCStreamStartError translates SCStream's userDeclined to
//     .notPermitted, anything else to .streamFailed.
//
// Camera / mic lookup misses (.sourceUnavailable) require a successful
// display lookup, which means constructing a real SCDisplay — there's no
// public initializer. Those are folded into the §4.5b smoke test.
final class LiveCaptureBackendTests: XCTestCase {

    private static let bundleURL = URL(fileURLWithPath: "/tmp/pixelbay-test-bundle")

    private func makePlan(
        source: CaptureSource,
        camera: String? = nil,
        audio: AudioSource = .none,
        includeSystemAudio: Bool = false
    ) -> CapturePlan {
        let outputs = CaptureOutputs(
            screenURL: Self.bundleURL.appendingPathComponent("media/screen-test.mov"),
            camURL: camera == nil ? nil : Self.bundleURL.appendingPathComponent("media/cam-test.mov"),
            micURL: audio == .none ? nil : Self.bundleURL.appendingPathComponent("media/mic-test.caf")
        )
        return CapturePlan(
            sessionID: "testsess",
            source: source,
            camera: camera,
            audio: audio,
            includeSystemAudio: includeSystemAudio,
            bundleURL: Self.bundleURL,
            outputs: outputs
        )
    }

    private func failingShareableContent() -> ShareableContentLookup {
        ShareableContentLookup(
            display: { id in
                throw CaptureError.sourceUnavailable(message: "fake: display \(id) absent")
            },
            window: { id in
                throw CaptureError.sourceUnavailable(message: "fake: window \(id) absent")
            }
        )
    }

    private func emptyDevices() -> CaptureDeviceLookup {
        CaptureDeviceLookup(
            camera: { _ in nil },
            microphone: { _ in nil }
        )
    }

    private func backend() -> LiveCaptureBackend {
        LiveCaptureBackend(
            sink: nil,
            shareableContent: failingShareableContent(),
            deviceLookup: emptyDevices(),
            firstSampleTimeout: 1
        )
    }

    func test_start_window_throwsSourceUnavailable() async {
        let plan = makePlan(source: .window(windowID: 42))
        do {
            _ = try await backend().start(plan: plan)
            XCTFail("expected throw")
        } catch let error as CaptureError {
            guard case .sourceUnavailable = error else {
                XCTFail("expected .sourceUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_start_area_throwsSourceUnavailable() async {
        let plan = makePlan(source: .area(rect: .zero, displayID: 1))
        do {
            _ = try await backend().start(plan: plan)
            XCTFail("expected throw")
        } catch let error as CaptureError {
            guard case .sourceUnavailable = error else {
                XCTFail("expected .sourceUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_start_device_throwsSourceUnavailable() async {
        let plan = makePlan(source: .device(deviceUniqueID: "iPhone-fake"))
        do {
            _ = try await backend().start(plan: plan)
            XCTFail("expected throw")
        } catch let error as CaptureError {
            guard case .sourceUnavailable = error else {
                XCTFail("expected .sourceUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_start_displayLookupFailure_propagatesAsSourceUnavailable() async {
        let plan = makePlan(source: .display(displayID: 99))
        do {
            _ = try await backend().start(plan: plan)
            XCTFail("expected throw")
        } catch let error as CaptureError {
            guard case .sourceUnavailable(let message) = error else {
                XCTFail("expected .sourceUnavailable, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("fake: display 99 absent"), "expected fake message, got: \(message)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_start_secondTimeOnSameInstance_throwsInvalidState() async {
        let inst = backend()
        // First call short-circuits in the switch and throws .sourceUnavailable
        // (which sets self.plan), so the second call should reject with
        // .invalidState — backend instances are single-use.
        _ = try? await inst.start(plan: makePlan(source: .window(windowID: 1)))
        do {
            _ = try await inst.start(plan: makePlan(source: .window(windowID: 1)))
            XCTFail("expected throw")
        } catch let error as CaptureError {
            guard case .invalidState = error else {
                XCTFail("expected .invalidState, got \(error)")
                return
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_mapSCStreamStartError_userDeclined_translatesToNotPermitted() {
        let nsError = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.userDeclined.rawValue,
            userInfo: nil
        )
        XCTAssertEqual(LiveCaptureBackend.mapSCStreamStartError(nsError), .notPermitted)
    }

    func test_mapSCStreamStartError_otherSCCode_translatesToStreamFailed() {
        let nsError = NSError(
            domain: SCStreamErrorDomain,
            code: -9999,
            userInfo: [NSLocalizedDescriptionKey: "weird SC error"]
        )
        let mapped = LiveCaptureBackend.mapSCStreamStartError(nsError)
        guard case .streamFailed(let message) = mapped else {
            XCTFail("expected .streamFailed, got \(mapped)")
            return
        }
        XCTAssertEqual(message, "weird SC error")
    }

    func test_mapSCStreamStartError_unrelatedDomain_translatesToStreamFailed() {
        let nsError = NSError(
            domain: "com.example.unrelated",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "totally different framework"]
        )
        let mapped = LiveCaptureBackend.mapSCStreamStartError(nsError)
        guard case .streamFailed(let message) = mapped else {
            XCTFail("expected .streamFailed, got \(mapped)")
            return
        }
        XCTAssertEqual(message, "totally different framework")
    }

    func test_captureSinkSummary_emptyHasAllNilDurations() {
        let summary = CaptureSinkSummary.empty
        XCTAssertNil(summary.screenDuration)
        XCTAssertNil(summary.camDuration)
        XCTAssertNil(summary.micDuration)
    }

    // MARK: - SCStreamBridge.isCompleteFrame (HANDOFF §3.16 iter #11)

    func test_isCompleteFrame_completeStatus_returnsTrue() throws {
        let buffer = try Self.makeSampleBuffer(status: .complete)
        XCTAssertTrue(SCStreamBridge.isCompleteFrame(buffer))
    }

    func test_isCompleteFrame_idleStatus_returnsFalse() throws {
        let buffer = try Self.makeSampleBuffer(status: .idle)
        XCTAssertFalse(SCStreamBridge.isCompleteFrame(buffer))
    }

    func test_isCompleteFrame_blankStatus_returnsFalse() throws {
        let buffer = try Self.makeSampleBuffer(status: .blank)
        XCTAssertFalse(SCStreamBridge.isCompleteFrame(buffer))
    }

    func test_isCompleteFrame_suspendedStatus_returnsFalse() throws {
        let buffer = try Self.makeSampleBuffer(status: .suspended)
        XCTAssertFalse(SCStreamBridge.isCompleteFrame(buffer))
    }

    func test_isCompleteFrame_noAttachments_returnsTrue() throws {
        // Synthetic buffers without attachments fall through to true so we
        // do not accidentally filter buffers a future caller injects directly.
        let buffer = try Self.makeSampleBuffer(status: nil)
        XCTAssertTrue(SCStreamBridge.isCompleteFrame(buffer))
    }

    private static func makeSampleBuffer(status: SCFrameStatus?) throws -> CMSampleBuffer {
        var formatDescription: CMFormatDescription?
        var status_ = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 16,
            height: 16,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status_, noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status_ = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status_, noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        if let status = status {
            // CMSampleBufferGetSampleAttachmentsArray with createIfNecessary:true
            // returns a CFArray of CFMutableDictionary refs we can populate.
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary]
            let attach = try XCTUnwrap(attachments?.first)
            CFDictionarySetValue(
                attach,
                Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
                Unmanaged.passUnretained(status.rawValue as CFNumber).toOpaque()
            )
        }
        return buffer
    }
}

#endif
