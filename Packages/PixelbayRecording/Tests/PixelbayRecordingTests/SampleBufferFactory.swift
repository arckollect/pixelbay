#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Synthetic CMSampleBuffer factory for AssetWriterPipeline tests. We
// fabricate sample buffers from CVPixelBuffers (video) and from raw PCM
// data (audio) so the tests never touch a real display, camera, or
// microphone — they exercise the pipeline's writer wiring against a real
// AVAssetWriter end-to-end (which uses the system H.264 encoder; that is
// available on every macOS dev machine).
enum SampleBufferFactory {

    enum FactoryError: Error {
        case pixelBufferAllocationFailed(OSStatus)
        case formatDescriptionFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case blockBufferFailed(OSStatus)
    }

    static func videoSample(
        width: Int = 320,
        height: Int = 240,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw FactoryError.pixelBufferAllocationFailed(status)
        }

        // Fill with opaque grey so the encoder has actual data to compress.
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            memset(base, 0x80, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let fmt = formatDesc else {
            throw FactoryError.formatDescriptionFailed(fmtStatus)
        }

        // Real AVCapture samples land here with PTS carrying
        // [.valid, .hasBeenRounded] — the rounded flag comes from
        // CMSyncConvertTime'ing capture-clock time into the writer's
        // domain. Test callers use the `value+timescale` shorthand which
        // produces [.valid] only; normalize so synthetic samples look
        // like production and the pipeline's "drop first frame at PTS 0
        // without HasBeenRounded" guard (HANDOFF §3.16 iter #14) does
        // not accidentally swallow test samples that legitimately start
        // at PTS 0.
        let normalizedPTS = CMTime(
            value: pts.value,
            timescale: pts.timescale,
            flags: [.valid, .hasBeenRounded],
            epoch: pts.epoch
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: normalizedPTS,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        guard sbStatus == noErr, let buf = sb else {
            throw FactoryError.sampleBufferFailed(sbStatus)
        }
        return buf
    }

    static func audioSample(
        sampleRate: Double = 44_100,
        channelCount: UInt32 = 1,
        frameCount: Int = 1024,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let fmt = formatDesc else {
            throw FactoryError.formatDescriptionFailed(fmtStatus)
        }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let dataLen = bytesPerFrame * frameCount
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLen,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLen,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == noErr, let block = blockBuffer else {
            throw FactoryError.blockBufferFailed(bbStatus)
        }
        // Zero the buffer (silence is a valid audio signal for tests).
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataLen)

        var sb: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sb
        )
        guard sbStatus == noErr, let buf = sb else {
            throw FactoryError.sampleBufferFailed(sbStatus)
        }
        return buf
    }
}
#endif
