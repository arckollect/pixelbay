import AVFoundation
import CoreGraphics
import Foundation
import PixelbayCore
@testable import PixelbayPlayback
import XCTest

final class PreviewCompositionTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixelbay-playback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("media"),
            withIntermediateDirectories: true
        )
        self.bundleURL = tmp
    }

    override func tearDownWithError() throws {
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }
    }

    func test_build_throws_whenProjectHasNoScreenTrack() async throws {
        let project = Project(name: "Empty")
        do {
            _ = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
            XCTFail("Expected noScreenAsset")
        } catch PreviewCompositionError.noScreenAsset {
            // expected — empty tracks ⇒ no screen track contributes
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_build_throws_fileNotFound_whenScreenAssetMissing() async throws {
        let project = makeProject(
            screenAssetPath: "media/screen-nonexistent.mov",
            screenSourceSeconds: 1,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 1
        )
        do {
            _ = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
            XCTFail("Expected fileNotFound")
        } catch PreviewCompositionError.fileNotFound {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_build_succeeds_withScreenOnly_whenWebcamMissing() async throws {
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 1.0, size: CGSize(width: 640, height: 360))

        let project = makeProject(
            screenAssetPath: "media/screen.mov",
            screenSourceSeconds: 1,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 1
        )
        let preview = try await PreviewCompositionBuilder.build(
            project: project,
            bundleURL: bundleURL
        )
        XCTAssertEqual(preview.outputSize, CGSize(width: 640, height: 360))
        XCTAssertNotNil(preview.videoComposition)
        XCTAssertGreaterThan(preview.duration.seconds, 0)
    }

    func test_outputSize_capsAt1080p_whenSourceIsLarger() async throws {
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 0.5, size: CGSize(width: 3840, height: 2160))

        let project = makeProject(
            screenAssetPath: "media/screen.mov",
            screenSourceSeconds: 0.5,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 0.5
        )
        let preview = try await PreviewCompositionBuilder.build(
            project: project,
            bundleURL: bundleURL
        )
        XCTAssertLessThanOrEqual(preview.outputSize.width, 1920)
        XCTAssertLessThanOrEqual(preview.outputSize.height, 1080)
        let aspect = preview.outputSize.width / preview.outputSize.height
        XCTAssertEqual(aspect, 16.0 / 9.0, accuracy: 0.01)
    }

    func test_outputSize_isEvenDimensions() async throws {
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 0.5, size: CGSize(width: 1367, height: 769))

        let project = makeProject(
            screenAssetPath: "media/screen.mov",
            screenSourceSeconds: 0.5,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 0.5
        )
        let preview = try await PreviewCompositionBuilder.build(
            project: project,
            bundleURL: bundleURL
        )
        XCTAssertEqual(Int(preview.outputSize.width) % 2, 0)
        XCTAssertEqual(Int(preview.outputSize.height) % 2, 0)
    }

    // MARK: - Multi-clip / Phase-2 honouring

    func test_build_honoursTrimmedSourceRange() async throws {
        // 2s source video; clip uses sourceRange 0.5..1.5 (1s slice) at
        // timeline 0..1s. Composition duration should be 1s, NOT 2s
        // (which is what the old "insert whole asset" path produced).
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 2.0, size: CGSize(width: 640, height: 360))

        let project = makeProject(
            screenAssetPath: "media/screen.mov",
            screenSourceSeconds: 2,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 1,
            screenSourceStartSeconds: 0.5
        )
        let preview = try await PreviewCompositionBuilder.build(
            project: project,
            bundleURL: bundleURL
        )
        XCTAssertEqual(preview.duration.seconds, 1.0, accuracy: 0.05)
    }

    func test_build_honoursTimelineGap_betweenClips() async throws {
        // Two clips with a 0.5s gap: clip A at timeline 0..1s, clip B at
        // timeline 1.5..2.5s. Duration should reflect B's end (2.5s),
        // not the sum of clip durations (2s).
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 3.0, size: CGSize(width: 640, height: 360))

        let assetID = MediaAssetID.generate()
        let asset = MediaAsset(
            id: assetID,
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: RationalTime.seconds(3)
        )
        let clipA = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(1)),
            timelineRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(1))
        )
        let clipB = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: RationalTime.seconds(1), duration: RationalTime.seconds(1)),
            timelineRange: TimeRange(start: RationalTime.seconds(1.5), duration: RationalTime.seconds(1))
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clipA, clipB])
        var project = Project(name: "Two-clip gap")
        project.assets = [asset]
        project.tracks = [track]

        let preview = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
        XCTAssertEqual(preview.duration.seconds, 2.5, accuracy: 0.05)
    }

    func test_build_emitsAudioMix_perClipVolumeRamp() async throws {
        // One screen clip + one audio clip with volume = 0.5. The
        // PreviewComposition should include a non-nil audioMix with
        // exactly one inputParameters entry.
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 0.5, size: CGSize(width: 640, height: 360))
        let micURL = bundleURL.appendingPathComponent("media/mic.caf")
        try writeSilentAudio(to: micURL, durationSeconds: 0.5)

        let screenAssetID = MediaAssetID.generate()
        let micAssetID = MediaAssetID.generate()
        var project = Project(name: "Mix")
        project.assets = [
            MediaAsset(id: screenAssetID, kind: .display, relativePath: "media/screen.mov",
                       captureStart: nil, nativeDuration: RationalTime.seconds(0.5)),
            MediaAsset(id: micAssetID, kind: .microphone, relativePath: "media/mic.caf",
                       captureStart: nil, nativeDuration: RationalTime.seconds(0.5))
        ]
        let screenClip = Clip(
            assetID: screenAssetID,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(0.5)),
            timelineRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(0.5))
        )
        let micClip = Clip(
            assetID: micAssetID,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(0.5)),
            timelineRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(0.5)),
            volume: 0.5
        )
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [screenClip]),
            Track(kind: .microphone, name: "Mic", clips: [micClip])
        ]

        let preview = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
        XCTAssertNotNil(preview.audioMix)
        XCTAssertEqual(preview.audioMix?.inputParameters.count, 1)
    }

    func test_build_scaledClip_atDoubleSpeed_yieldsHalfTimelineDuration() async throws {
        // 1s source video; clip's timelineRange.duration = 0.5s (i.e. 2× speed).
        // PreviewCompositionBuilder must call scaleTimeRange so the composition
        // plays the source out in the timeline's 0.5s window — not 1s.
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 1.0, size: CGSize(width: 640, height: 360))

        let assetID = MediaAssetID.generate()
        let asset = MediaAsset(
            id: assetID,
            kind: .display,
            relativePath: "media/screen.mov",
            captureStart: nil,
            nativeDuration: RationalTime.seconds(1)
        )
        let clip = Clip(
            assetID: assetID,
            sourceRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(1)),
            timelineRange: TimeRange(start: RationalTime.seconds(0), duration: RationalTime.seconds(0.5)),
            speed: 2.0
        )
        var project = Project(name: "Speed 2x")
        project.assets = [asset]
        project.tracks = [Track(kind: .screen, name: "Screen", clips: [clip])]

        let preview = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
        XCTAssertEqual(preview.duration.seconds, 0.5, accuracy: 0.05)
    }

    func test_build_shortSourceWithPaddedTimeline_doesNotStretchVideo() async throws {
        // Repro of the cam-clip-too-short bug. A 10s screen recording with
        // a 3s webcam: RecordingService now pads the webcam clip's
        // timelineRange to 10s so the timeline UI shows it as 10s and
        // the user can edit it without surprise. With `clip.speed == 1.0`
        // the compositor must NOT scaleTimeRange (which would slow the
        // 3s webcam to fill 10s); it should leave the [3s, 10s] tail
        // empty/transparent and the resulting composition should be 10s
        // long, not 30s.
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 10.0, size: CGSize(width: 640, height: 360))
        let camURL = bundleURL.appendingPathComponent("media/cam.mov")
        try writeSilentVideo(to: camURL, durationSeconds: 3.0, size: CGSize(width: 320, height: 240))

        let screenAssetID = MediaAssetID.generate()
        let screenAsset = MediaAsset(
            id: screenAssetID,
            kind: .display,
            relativePath: "media/screen.mov",
            nativeDuration: RationalTime.seconds(10)
        )
        let camAssetID = MediaAssetID.generate()
        let camAsset = MediaAsset(
            id: camAssetID,
            kind: .webcam,
            relativePath: "media/cam.mov",
            nativeDuration: RationalTime.seconds(3)
        )
        let screenClip = Clip(
            assetID: screenAssetID,
            sourceRange: TimeRange(start: .zero, duration: .seconds(10)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(10))
        )
        // The bug-fix clip: timelineRange = 10s, sourceRange = 3s,
        // speed = 1.0 (the default). Composition should be 10s long
        // with the first 3s carrying cam content.
        let camClip = Clip(
            assetID: camAssetID,
            sourceRange: TimeRange(start: .zero, duration: .seconds(3)),
            timelineRange: TimeRange(start: .zero, duration: .seconds(10))
        )
        var project = Project(name: "Padded cam")
        project.assets = [screenAsset, camAsset]
        project.tracks = [
            Track(kind: .screen, name: "Screen", clips: [screenClip]),
            Track(kind: .webcam, name: "Webcam", clips: [camClip])
        ]

        let preview = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
        // Composition duration is the longer of the two tracks' ranges,
        // which is 10s. Were the compositor to scale the 3s cam to 10s
        // it would still report 10s (the scaling is on the cam track
        // only), so this assertion alone doesn't prove the fix. The
        // stronger check is that the cam composition track has exactly
        // 3s of content and a 7s trailing empty range — see below.
        XCTAssertEqual(preview.duration.seconds, 10.0, accuracy: 0.05)

        // Inspect the AVMutableComposition's webcam track to confirm the
        // inserted source span is 3s (not stretched to 10s) and the
        // overall track range still reaches 10s via the implicit
        // trailing empty time.
        let webcamTracks = preview.composition.tracks(withMediaType: .video)
            .filter { $0.timeRange.duration.seconds < 9.5 || $0.timeRange.duration.seconds > 10.5 ? false : true }
        // ^ both tracks span up to 10s; pick by segments.
        // Find the cam track: it has exactly one non-empty segment of 3s.
        let camTrack = preview.composition.tracks(withMediaType: .video).first {
            $0.segments.contains(where: { !$0.isEmpty && $0.timeMapping.target.duration.seconds > 2.5 && $0.timeMapping.target.duration.seconds < 3.5 })
        }
        XCTAssertNotNil(camTrack, "webcam track should keep the 3s source segment without scaling")
        if let camTrack {
            let nonEmpty = camTrack.segments.filter { !$0.isEmpty }
            XCTAssertEqual(nonEmpty.count, 1, "exactly one non-empty cam segment")
            XCTAssertEqual(nonEmpty.first?.timeMapping.target.duration.seconds ?? 0, 3.0, accuracy: 0.1)
        }
        _ = webcamTracks
    }

    func test_build_noAudioTracks_yieldsNilAudioMix() async throws {
        // Pure-video project (no microphone / systemAudio / voiceover
        // tracks) → audioMix is nil so AVPlayer / AVAssetExportSession
        // skip the mix entirely.
        let screenURL = bundleURL.appendingPathComponent("media/screen.mov")
        try writeSilentVideo(to: screenURL, durationSeconds: 0.5, size: CGSize(width: 640, height: 360))

        let project = makeProject(
            screenAssetPath: "media/screen.mov",
            screenSourceSeconds: 0.5,
            screenTimelineStartSeconds: 0,
            screenTimelineDurationSeconds: 0.5
        )
        let preview = try await PreviewCompositionBuilder.build(project: project, bundleURL: bundleURL)
        XCTAssertNil(preview.audioMix)
    }

    // MARK: - Track-and-clip fixture helper

    /// Wraps a single screen asset+clip into a `Project` with one track.
    /// Tests can override the source range start to exercise trim, and
    /// timelineDurationSeconds to exercise timeline length.
    private func makeProject(
        screenAssetPath: String,
        screenSourceSeconds: Double,
        screenTimelineStartSeconds: Double,
        screenTimelineDurationSeconds: Double,
        screenSourceStartSeconds: Double = 0
    ) -> Project {
        let assetID = MediaAssetID.generate()
        let asset = MediaAsset(
            id: assetID,
            kind: .display,
            relativePath: screenAssetPath,
            captureStart: nil,
            nativeDuration: RationalTime.seconds(screenSourceSeconds)
        )
        let clip = Clip(
            assetID: assetID,
            sourceRange: TimeRange(
                start: RationalTime.seconds(screenSourceStartSeconds),
                duration: RationalTime.seconds(screenTimelineDurationSeconds)
            ),
            timelineRange: TimeRange(
                start: RationalTime.seconds(screenTimelineStartSeconds),
                duration: RationalTime.seconds(screenTimelineDurationSeconds)
            )
        )
        let track = Track(kind: .screen, name: "Screen", clips: [clip])
        var project = Project(name: "Test")
        project.assets = [asset]
        project.tracks = [track]
        return project
    }

    // MARK: - Helpers

    /// Writes a tiny H.264 .mov for testing PreviewCompositionBuilder. The
    /// file has a single video track; no audio. Black frames at 30fps.
    private func writeSilentVideo(to url: URL, durationSeconds: Double, size: CGSize) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw NSError(domain: "PreviewCompositionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "startWriting: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)

        let frameRate: Int32 = 30
        let frameCount = max(1, Int(durationSeconds * Double(frameRate)))
        let frameDuration = CMTime(value: 1, timescale: frameRate)
        var pixelBuffer: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &pixelBuffer
        )
        guard pbStatus == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "PreviewCompositionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "pixel buffer create"])
        }
        // Zero-fill — black frame is fine for the tests.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            memset(base, 0, stride * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            if !pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw NSError(domain: "PreviewCompositionTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "append failed: \(String(describing: writer.error))"])
            }
        }
        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        if writer.status == .failed {
            throw NSError(domain: "PreviewCompositionTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "finishWriting failed: \(String(describing: writer.error))"])
        }
    }

    /// Writes a tiny silent .caf for testing the audio-mix path. Mono
    /// LPCM Float32 at 48kHz, zeroed samples for the requested duration.
    private func writeSilentAudio(to url: URL, durationSeconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw NSError(domain: "PreviewCompositionTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "audio startWriting: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)

        let sampleRate: Int32 = 48000
        let frameCount = Int(durationSeconds * Double(sampleRate))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let fdStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard fdStatus == noErr, let formatDesc else {
            throw NSError(domain: "PreviewCompositionTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "audio format desc"])
        }

        let bytesPerFrame = 4
        let totalBytes = frameCount * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw NSError(domain: "PreviewCompositionTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "block buffer alloc"])
        }
        // Zero-fill (silence).
        let fillStatus = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: totalBytes)
        guard fillStatus == kCMBlockBufferNoErr else {
            throw NSError(domain: "PreviewCompositionTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "block buffer fill"])
        }
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "PreviewCompositionTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "sample buffer create"])
        }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        if !input.append(sampleBuffer) {
            throw NSError(domain: "PreviewCompositionTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "audio append: \(String(describing: writer.error))"])
        }
        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        if writer.status == .failed {
            throw NSError(domain: "PreviewCompositionTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "audio finishWriting: \(String(describing: writer.error))"])
        }
    }
}
