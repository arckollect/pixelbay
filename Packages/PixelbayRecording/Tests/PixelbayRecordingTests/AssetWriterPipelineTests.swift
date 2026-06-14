#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import PixelbayCapture
import PixelbayCore
import XCTest
@testable import PixelbayRecording

final class AssetWriterPipelineTests: XCTestCase {

    private var bundleURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixelbay-recording-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ProjectBundle.pathExtension)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("media"),
            withIntermediateDirectories: true
        )
        bundleURL = base
    }

    override func tearDownWithError() throws {
        if let url = bundleURL {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: parent)
        }
        bundleURL = nil
        try super.tearDownWithError()
    }

    private func makeConfig(
        sysAudioURL: URL? = nil,
        camURL: URL? = nil,
        micURL: URL? = nil
    ) -> AssetWriterPipeline.Configuration {
        AssetWriterPipeline.Configuration(
            screenURL: bundleURL.appendingPathComponent("media/screen-test.mov"),
            camURL: camURL,
            micURL: micURL,
            sysAudioURL: sysAudioURL,
            bundleURL: bundleURL
        )
    }

    private var markerURL: URL {
        bundleURL.appendingPathComponent("media").appendingPathComponent(AssetWriterPipeline.recordingMarkerFilename)
    }

    /// A plausible host-clock PTS base in seconds (≈ machine uptime).
    /// Production SCStream / locked-cam samples carry host-clock
    /// (seconds-since-boot) timestamps, always far above
    /// `AssetWriterPipeline.minPlausibleHostClockPTSSeconds`. The synthetic
    /// `SampleBufferFactory` defaults to a ~0 origin, so any test exercising
    /// the normal write path must offset its PTS into the host-clock domain
    /// or the pipeline's pre-lock-frame drop (HANDOFF §3.16 iter #14) treats
    /// every frame as suspect and discards it. Durations are deltas, so the
    /// offset doesn't perturb any duration assertion.
    private static let hostClockBaseSeconds: Int64 = 100_000

    /// Build a host-clock-domain PTS for `frame` at `timescale`.
    private func hostPTS(frame: Int, timescale: Int32) -> CMTime {
        CMTime(
            value: Self.hostClockBaseSeconds * Int64(timescale) + CMTimeValue(frame),
            timescale: timescale
        )
    }

    // MARK: - Screen video quality

    func test_videoBitrate_usesOpenScreenStyleFloorFor1080p60Text() {
        XCTAssertEqual(
            AssetWriterPipeline.videoBitrate(width: 1920, height: 1080),
            30_600_000
        )
    }

    func test_videoBitrate_usesQHDFloorBeforeDensityTargetCatchesUp() {
        XCTAssertEqual(
            AssetWriterPipeline.videoBitrate(width: 2560, height: 1440),
            47_600_000
        )
    }

    func test_videoBitrate_allowsDenseRetinaFramesAboveLadderFloor() {
        XCTAssertEqual(
            AssetWriterPipeline.videoBitrate(width: 3456, height: 2234),
            83_383_603
        )
    }

    // MARK: - Marker file

    func test_constructor_createsRecordingMarkerFile() throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig())
        _ = pipeline
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "expected .recording-in-progress marker at \(markerURL.path)"
        )
    }

    func test_finish_withNoSamples_removesMarkerFile_andReturnsEmptySummary() async throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig())
        let summary = try await pipeline.finish()
        XCTAssertNil(summary.screenDuration)
        XCTAssertNil(summary.camDuration)
        XCTAssertNil(summary.micDuration)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "marker file should be removed by finish()"
        )
    }

    func test_finish_calledTwice_throwsAlreadyFinished() async throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig())
        _ = try await pipeline.finish()
        do {
            _ = try await pipeline.finish()
            XCTFail("expected throw on second finish()")
        } catch let error as AssetWriterPipeline.RecordingError {
            XCTAssertEqual(error, .alreadyFinished)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Single-track writers

    func test_appendCamVideoSamples_writesMov_andSummaryReportsDuration() async throws {
        let camURL = bundleURL.appendingPathComponent("media/cam-test.mov")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(camURL: camURL))

        let timescale: Int32 = 60
        for frame in 0..<6 {
            let pts = hostPTS(frame: frame, timescale: timescale)
            let sb = try SampleBufferFactory.videoSample(pts: pts)
            pipeline.append(sb, on: .camVideo)
        }
        let summary = try await pipeline.finish()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: camURL.path),
            "expected cam.mov to exist at \(camURL.path)"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: camURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "cam.mov should be non-empty")

        XCTAssertNotNil(summary.camDuration)
        // 6 frames at 60fps = 5 frame intervals = 5/60s ≈ 0.0833s. The
        // pipeline canonicalises duration onto RationalTime's default
        // timescale (600), so we assert on .seconds rather than the raw
        // value/timescale pair.
        XCTAssertEqual(summary.camDuration?.seconds ?? .nan, 5.0 / 60.0, accuracy: 1e-6)
        XCTAssertNil(summary.screenDuration)
        XCTAssertNil(summary.micDuration)
    }

    func test_appendScreenVideo_writesScreenMov() async throws {
        // screen.mov is single-track-video as of iter 10 — no `expectsAudio`
        // path to coordinate with. Same shape as cam.mov.
        let pipeline = try AssetWriterPipeline(configuration: makeConfig())

        for frame in 0..<4 {
            let pts = hostPTS(frame: frame, timescale: 60)
            let sb = try SampleBufferFactory.videoSample(pts: pts)
            pipeline.append(sb, on: .screenVideo)
        }
        let summary = try await pipeline.finish()

        let screenURL = bundleURL.appendingPathComponent("media/screen-test.mov")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: screenURL.path),
            "expected screen.mov to exist"
        )
        XCTAssertNotNil(summary.screenDuration)
    }

    func test_appendSysAudio_writesSysAudioCaf() async throws {
        let sysURL = bundleURL.appendingPathComponent("media/sysaudio-test.caf")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(sysAudioURL: sysURL))

        let timescale: Int32 = 48_000
        for chunk in 0..<4 {
            let pts = CMTime(value: CMTimeValue(chunk * 1024), timescale: timescale)
            let sb = try SampleBufferFactory.audioSample(pts: pts)
            pipeline.append(sb, on: .screenAudio)
        }
        let summary = try await pipeline.finish()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sysURL.path),
            "expected sysaudio.caf to exist"
        )
        XCTAssertNotNil(summary.sysAudioDuration)
        XCTAssertNil(summary.screenDuration)
    }

    func test_appendScreenAudio_whenSysAudioURLIsNil_isNoOp() async throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(sysAudioURL: nil))
        let sb = try SampleBufferFactory.audioSample(pts: .zero)
        pipeline.append(sb, on: .screenAudio)
        let summary = try await pipeline.finish()
        XCTAssertNil(summary.sysAudioDuration)
    }

    func test_appendMicAudio_writesCaf_andSummaryReportsDuration() async throws {
        let micURL = bundleURL.appendingPathComponent("media/mic-test.caf")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(micURL: micURL))

        let timescale: Int32 = 44_100
        for chunk in 0..<4 {
            let pts = CMTime(value: CMTimeValue(chunk * 1024), timescale: timescale)
            let sb = try SampleBufferFactory.audioSample(pts: pts)
            pipeline.append(sb, on: .micAudio)
        }
        let summary = try await pipeline.finish()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: micURL.path),
            "expected mic.caf to exist"
        )
        XCTAssertNotNil(summary.micDuration)
        XCTAssertNil(summary.screenDuration)
        XCTAssertNil(summary.camDuration)
    }

    // MARK: - URL gating

    func test_appendCamVideo_whenCamURLIsNil_isNoOp() async throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(camURL: nil))
        let sb = try SampleBufferFactory.videoSample(pts: .zero)
        pipeline.append(sb, on: .camVideo)
        let summary = try await pipeline.finish()
        XCTAssertNil(summary.camDuration)
    }

    func test_appendMicAudio_whenMicURLIsNil_isNoOp() async throws {
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(micURL: nil))
        let sb = try SampleBufferFactory.audioSample(pts: .zero)
        pipeline.append(sb, on: .micAudio)
        let summary = try await pipeline.finish()
        XCTAssertNil(summary.micDuration)
    }

    // MARK: - Independent track files

    func test_screenAndSysAudio_writeIndependentFiles() async throws {
        // As of iter 10, screen.mov and sysaudio.caf are independent
        // single-track writers — no startWriting coordination needed.
        let sysURL = bundleURL.appendingPathComponent("media/sysaudio-test.caf")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(sysAudioURL: sysURL))

        for frame in 0..<4 {
            let pts = hostPTS(frame: frame, timescale: 60)
            let sb = try SampleBufferFactory.videoSample(pts: pts)
            pipeline.append(sb, on: .screenVideo)
        }
        for chunk in 0..<3 {
            let pts = CMTime(value: CMTimeValue(chunk * 1024), timescale: 48_000)
            let sb = try SampleBufferFactory.audioSample(pts: pts)
            pipeline.append(sb, on: .screenAudio)
        }
        let summary = try await pipeline.finish()

        let screenURL = bundleURL.appendingPathComponent("media/screen-test.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sysURL.path))
        XCTAssertNotNil(summary.screenDuration)
        XCTAssertNotNil(summary.sysAudioDuration)
    }

    // MARK: - HANDOFF §3.16 iter #14: drop AVCapture's unsynchronised
    // first frame at PTS 0 / flags=[.valid]

    func test_handleSingleVideo_dropsFirstFrameWithSuspectPTS() async throws {
        // Reproduces the AVCaptureVideoDataOutput "first frame before
        // sync clock locks" quirk: PTS=0/timescale, flags=[.valid] only
        // (no HasBeenRounded — the timestamp was never converted into a
        // real clock domain). The pipeline must drop this sample so the
        // writer doesn't latch its session start onto PTS 0; the next
        // sample with a normal host-clock PTS (≈ 1e11) would then make
        // the .mov report a ~38-hour duration.
        let camURL = bundleURL.appendingPathComponent("media/cam-test.mov")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(camURL: camURL))

        // Suspect first frame: PTS=0, flags=[.valid] only.
        let suspectPTS = CMTime(value: 0, timescale: 60, flags: [.valid], epoch: 0)
        let suspect = try SampleBufferFactory.videoSample(pts: suspectPTS)
        // Override: use a sample buffer whose PTS truly carries flags=[.valid]
        // only — go through CMSampleBufferCreateCopyWithNewTiming so we can
        // set the timing without the factory's normalization.
        var rawTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: suspectPTS,
            decodeTimeStamp: .invalid
        )
        var rewritten: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: suspect,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &rawTiming,
            sampleBufferOut: &rewritten
        )
        XCTAssertEqual(copyStatus, noErr)
        let suspectBuf = try XCTUnwrap(rewritten)
        pipeline.append(suspectBuf, on: .camVideo)

        // Real subsequent frames at genuine host-clock PTS (seconds-since-boot).
        for frame in 1...4 {
            let pts = hostPTS(frame: frame, timescale: 60)
            let sb = try SampleBufferFactory.videoSample(pts: pts)
            pipeline.append(sb, on: .camVideo)
        }
        let summary = try await pipeline.finish()

        // Expected: writer started on host-frame 1, last sample at host-frame
        // 4, duration = 3/60s. Without the iter-#14 drop, the writer would
        // latch onto PTS 0 and report a duration of ~hostClockBaseSeconds.
        XCTAssertNotNil(summary.camDuration)
        XCTAssertEqual(summary.camDuration?.seconds ?? .nan, 3.0 / 60.0, accuracy: 1e-6)
    }

    func test_handleSingleVideo_dropsWarmRestartPreLockFrame() async throws {
        // Broadened iter-#14 case: between scenes, the cam can emit a
        // pre-lock frame at a small *non-zero* PTS (observed 0.033 s) that
        // the original `pts == 0` test let through, corrupting cam-*.mov.
        // The `< minPlausibleHostClockPTSSeconds` rule must drop it too.
        let camURL = bundleURL.appendingPathComponent("media/cam-test.mov")
        let pipeline = try AssetWriterPipeline(configuration: makeConfig(camURL: camURL))

        // Warm-restart pre-lock frame: PTS ≈ 0.033 s, well under 1 s.
        let preLock = try SampleBufferFactory.videoSample(
            pts: CMTime(value: 2, timescale: 60)
        )
        pipeline.append(preLock, on: .camVideo)

        for frame in 1...4 {
            let pts = hostPTS(frame: frame, timescale: 60)
            let sb = try SampleBufferFactory.videoSample(pts: pts)
            pipeline.append(sb, on: .camVideo)
        }
        let summary = try await pipeline.finish()

        // The 0.033 s frame is dropped, so the writer latches onto the first
        // host-clock frame; duration is the 3/60 s span of the real frames,
        // not the ~hostClockBaseSeconds a mixed-domain latch would report.
        XCTAssertNotNil(summary.camDuration)
        XCTAssertEqual(summary.camDuration?.seconds ?? .nan, 3.0 / 60.0, accuracy: 1e-6)
    }
}
#endif
