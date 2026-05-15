#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import CoreVideo
import Foundation
import OSLog
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "PixelbayVideoCompositor")

// AVVideoCompositing adapter that AVMutableVideoComposition.customVideoCompositorClass
// points at. Both preview (AVPlayer) and export (AVAssetExportSession) end up
// here with an AVAsynchronousVideoCompositionRequest per frame; we pull the
// per-track CVPixelBuffers, hand them to the MetalRenderGraph, and finish the
// request with the composited buffer.
//
// The mapping from AVFoundation track ID → LayerKind is set up by
// PreviewPlayer when it builds the AVMutableComposition: it puts screen on
// one track, webcam on another, and stamps both via
// PixelbayCompositionInstruction (which stores `[CMPersistentTrackID: LayerKind]`
// in instruction-side state). The compositor reads that mapping per request.
public final class PixelbayVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public override init() {
        // The render graph init can fail (no Metal device, shader load, etc.)
        // — this is rare on macOS 14, but if it happens the compositor falls
        // back to passing the screen layer through unmodified so playback
        // doesn't fail outright.
        let graph: MetalRenderGraph?
        do {
            graph = try MetalRenderGraph()
        } catch {
            log.error("MetalRenderGraph init failed: \(String(describing: error), privacy: .public). Falling back to screen-only passthrough.")
            graph = nil
        }
        self.renderGraph = graph
        super.init()
    }

    // MARK: AVVideoCompositing

    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] as [UInt32],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA as UInt32,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    public let supportsHDRSourceFrames: Bool = false
    public let supportsWideColorSourceFrames: Bool = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.handle(request: request)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync {
            self.cancelled = true
        }
        renderQueue.async {
            self.cancelled = false
        }
    }

    // MARK: - Internals

    private let renderQueue = DispatchQueue(label: "com.pixelbay.compositor.render")
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false
    private let renderGraph: MetalRenderGraph?

    /// Half-window for the cursor-velocity finite difference. Matches the
    /// `ClickLogger.moveDecimationInterval` default (1/120s) so each side
    /// of the bracket is one decimated sample away on a typical recording.
    private static let cursorVelocityHalfWindow: Double = 1.0 / 120.0

    private func handle(request: AVAsynchronousVideoCompositionRequest) {
        if cancelled {
            request.finishCancelledRequest()
            return
        }

        guard let instruction = request.videoCompositionInstruction as? PixelbayCompositionInstruction else {
            // Misconfigured composition — finish with an error rather than
            // silently producing a black frame.
            request.finish(with: PixelbayCompositionError.missingInstruction)
            return
        }

        let baseLayout = instruction.layout
        // Phase 3b — bake the per-frame effect state into the layout.
        // `request.compositionTime` is in the composition's time domain;
        // EffectKeyframe stores its ranges in the same domain, so we use
        // the raw seconds directly.
        let layout: ResolvedLayout
        if instruction.effects.isEmpty {
            layout = baseLayout
        } else {
            let t = CMTimeGetSeconds(request.compositionTime)
            layout = EffectEvaluator.apply(
                keyframes: instruction.effects,
                baseLayout: baseLayout,
                atTime: t
            )
        }
        var sources: [LayerKind: CVPixelBuffer] = [:]
        for (trackID, kind) in instruction.layerMapping {
            if let buffer = request.sourceFrame(byTrackID: trackID) {
                sources[kind] = buffer
            }
        }

        guard let context = renderContext, let destination = context.newPixelBuffer() else {
            request.finish(with: PixelbayCompositionError.noPixelBufferFromContext)
            return
        }

        // Phase 3c — resolve the synthetic cursor's per-frame state, if
        // enabled. All three of (sprite, settings.isEnabled, non-empty
        // trajectory) must be present for the pass to run; otherwise we
        // pass nil and the render graph skips it. The trajectory's
        // timelineTime is in the same composition-time domain as
        // `request.compositionTime`, so we sample directly.
        let cursorState: CursorRenderState?
        if let sprite = instruction.cursorSprite,
           let cursorSettings = instruction.cursorSettings,
           cursorSettings.isEnabled,
           !instruction.cursorTrajectory.isEmpty {
            let t = CMTimeGetSeconds(request.compositionTime)
            let position = sampleCursorTrajectory(instruction.cursorTrajectory, at: t)
            // Velocity via centred finite difference. dt = 1/120s gives a
            // bracket that's tight enough not to over-smooth quick direction
            // changes but wide enough that two adjacent trajectory samples
            // (recorded at 1/120s decimation) usually bracket it on each side.
            let dt = Self.cursorVelocityHalfWindow
            let prior = sampleCursorTrajectory(instruction.cursorTrajectory, at: t - dt)
            let next = sampleCursorTrajectory(instruction.cursorTrajectory, at: t + dt)
            let vx = (next.x - prior.x) / (2 * dt)
            let vy = (next.y - prior.y) / (2 * dt)
            cursorState = CursorRenderState(
                xFractionInScreen: position.x,
                yFractionInScreen: position.y,
                scale: cursorSettings.scale,
                velocityXFractionPerSecond: vx,
                velocityYFractionPerSecond: vy
            )
            _ = sprite // keep clarity; sprite is forwarded below
        } else {
            cursorState = nil
        }

        if let renderGraph {
            do {
                // Wrap the request + destination so they can ride along
                // into the @Sendable completion closure. Neither
                // AVAsynchronousVideoCompositionRequest nor CVPixelBuffer
                // is formally Sendable, but for the closure's purpose
                // (read-only finish call, then closure deallocates) the
                // @unchecked wrapper is sound.
                let bridge = AsyncRequestBridge(request: request, destination: destination)
                try renderGraph.render(
                    layout: layout,
                    sources: sources,
                    destination: destination,
                    cursorSprite: cursorState != nil ? instruction.cursorSprite : nil,
                    cursorState: cursorState,
                    completion: {
                        // Called on Metal's internal queue once the GPU
                        // finishes — calling request.finish here (rather
                        // than after `commandBuffer.waitUntilCompleted`)
                        // is what lets the render queue start frame N+1's
                        // CPU encoding while frame N is still on the GPU.
                        bridge.request.finish(withComposedVideoFrame: bridge.destination)
                    }
                )
            } catch {
                log.error("render() failed: \(String(describing: error), privacy: .public)")
                // Fall through to passthrough — synchronous, finish now.
                passthroughScreen(into: destination, sources: sources)
                request.finish(withComposedVideoFrame: destination)
            }
        } else {
            passthroughScreen(into: destination, sources: sources)
            request.finish(withComposedVideoFrame: destination)
        }
    }

    /// Bridges the non-Sendable `AVAsynchronousVideoCompositionRequest`
    /// and `CVPixelBuffer` across the async commit completion handler.
    /// AVFoundation's request finishing API is documented as safe to
    /// call from any thread; the destination buffer is only read by
    /// AVFoundation after `finish` is called.
    private struct AsyncRequestBridge: @unchecked Sendable {
        let request: AVAsynchronousVideoCompositionRequest
        let destination: CVPixelBuffer
    }

    // Phase 3c — sample the master cursor trajectory at the given
    // composition-time. Non-uniform Catmull-Rom (Barry-Goldman recursive
    // Lagrange form) across the bracketing samples so velocity stays
    // continuous AND correctly weighted when the time spacing between
    // captured samples varies — which it always does, because CGEventTap
    // delivers events at the system-native rate and macOS coalesces
    // during fast cursor sweeps (a sweep across the screen can drop the
    // effective sample rate from ~120 Hz to 30 Hz mid-motion). The
    // earlier *uniform* Catmull-Rom assumed equal spacing in the t
    // parameter and produced a velocity overshoot at every sample whose
    // neighbour spacing changed — exactly the "looks like frames are
    // skipped" stutter the user reported during fast moves.
    //
    // Falls back to linear when only ≤ 2 samples bracket the lookup
    // (no outer neighbours to parameterise the cubic). The cursor
    // sprite path does NOT pre-smooth the trajectory upstream — EMA
    // introduces visible lag at typical capture rates; the proper
    // non-uniform interp is what actually makes the motion read as
    // smooth without trailing the input. Out-of-range lookups clamp
    // to the first / last sample (no extrapolation).
    //
    // Linear scan is acceptable for v1: at 120 Hz, a 10-minute
    // recording is ~72k samples and per-frame O(n) is ~4 M
    // comparisons / sec at 60 fps. If profiles ever say otherwise,
    // switch to a binary search or keep a per-stream cursor index
    // between frames.
    private func sampleCursorTrajectory(
        _ samples: [MouseTrajectorySample],
        at t: Double
    ) -> (x: Double, y: Double) {
        guard let first = samples.first else { return (0.5, 0.5) }
        if t <= first.timelineTime {
            return (first.centerX, first.centerY)
        }
        let last = samples[samples.count - 1]
        if t >= last.timelineTime {
            return (last.centerX, last.centerY)
        }
        for i in 1..<samples.count {
            let b = samples[i]
            if t <= b.timelineTime {
                let a = samples[i - 1]
                let span = b.timelineTime - a.timelineTime
                if span <= 0 { return (b.centerX, b.centerY) }
                if samples.count <= 2 {
                    let u = (t - a.timelineTime) / span
                    return (
                        a.centerX + (b.centerX - a.centerX) * u,
                        a.centerY + (b.centerY - a.centerY) * u
                    )
                }
                let p0 = (i - 2) >= 0 ? samples[i - 2] : a
                let p3 = (i + 1) < samples.count ? samples[i + 1] : b
                return nonUniformCatmullRom2D(
                    p0t: p0.timelineTime, p0x: p0.centerX, p0y: p0.centerY,
                    p1t: a.timelineTime, p1x: a.centerX, p1y: a.centerY,
                    p2t: b.timelineTime, p2x: b.centerX, p2y: b.centerY,
                    p3t: p3.timelineTime, p3x: p3.centerX, p3y: p3.centerY,
                    at: t
                )
            }
        }
        return (last.centerX, last.centerY)
    }

    // Last-resort: copy the screen layer's pixels into the destination buffer
    // when Metal isn't available. Keeps preview alive on degraded systems
    // (CI, old Macs) at the cost of losing the cam overlay.
    private func passthroughScreen(into destination: CVPixelBuffer, sources: [LayerKind: CVPixelBuffer]) {
        guard let screen = sources[.screen] else { return }
        let lockSource = CVPixelBufferLockBaseAddress(screen, .readOnly)
        let lockDest = CVPixelBufferLockBaseAddress(destination, [])
        defer {
            if lockSource == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(screen, .readOnly) }
            if lockDest == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(destination, []) }
        }
        guard lockSource == kCVReturnSuccess, lockDest == kCVReturnSuccess else { return }
        let srcWidth = CVPixelBufferGetWidth(screen)
        let srcHeight = CVPixelBufferGetHeight(screen)
        let dstWidth = CVPixelBufferGetWidth(destination)
        let dstHeight = CVPixelBufferGetHeight(destination)
        let srcFormat = CVPixelBufferGetPixelFormatType(screen)
        let dstFormat = CVPixelBufferGetPixelFormatType(destination)
        guard srcWidth == dstWidth, srcHeight == dstHeight,
              srcFormat == dstFormat else {
            // Fallback can't handle resampling/format conversion — leave the
            // destination cleared.
            return
        }
        // Plane-by-plane copy (handles single-plane BGRA and bi-planar NV12).
        let planeCount = max(CVPixelBufferGetPlaneCount(screen), 1)
        if planeCount == 1 {
            if let src = CVPixelBufferGetBaseAddress(screen),
               let dst = CVPixelBufferGetBaseAddress(destination) {
                let stride = min(CVPixelBufferGetBytesPerRow(screen), CVPixelBufferGetBytesPerRow(destination))
                let height = min(srcHeight, dstHeight)
                memcpy(dst, src, stride * height)
            }
        } else {
            for plane in 0..<planeCount {
                if let src = CVPixelBufferGetBaseAddressOfPlane(screen, plane),
                   let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) {
                    let stride = min(
                        CVPixelBufferGetBytesPerRowOfPlane(screen, plane),
                        CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                    )
                    let height = min(
                        CVPixelBufferGetHeightOfPlane(screen, plane),
                        CVPixelBufferGetHeightOfPlane(destination, plane)
                    )
                    memcpy(dst, src, stride * height)
                }
            }
        }
    }
}

public enum PixelbayCompositionError: Error {
    case missingInstruction
    case noPixelBufferFromContext
}

// AVMutableVideoComposition's instruction is what carries per-segment state.
// PreviewPlayer constructs one with the layout + the trackID→LayerKind
// mapping it set up when adding the screen / webcam tracks.
public final class PixelbayCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = false
    public let containsTweening: Bool = false
    public var requiredSourceTrackIDs: [NSValue]? {
        layerMapping.keys.map { NSNumber(value: $0) }
    }
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    // Pixelbay-specific:
    public let layout: ResolvedLayout
    public let layerMapping: [CMPersistentTrackID: LayerKind]
    // Phase 3b — per-frame visual effects applied on top of `layout`.
    // Empty array preserves the static-layout behavior. Compositor walks
    // these per startRequest using request.compositionTime as the
    // playhead t.
    public let effects: [EffectKeyframe]
    // Phase 3c — synthetic cursor pass inputs.
    //
    // All three are required together: empty trajectory, nil sprite, or
    // `cursorSettings.isEnabled == false` each disable the pass
    // independently. The compositor samples `cursorTrajectory` at
    // `request.compositionTime` to derive the per-frame cursor position.
    public let cursorSprite: CursorSpriteData?
    public let cursorSettings: CursorSettings?
    public let cursorTrajectory: [MouseTrajectorySample]

    public init(
        timeRange: CMTimeRange,
        layout: ResolvedLayout,
        layerMapping: [CMPersistentTrackID: LayerKind],
        effects: [EffectKeyframe] = [],
        cursorSprite: CursorSpriteData? = nil,
        cursorSettings: CursorSettings? = nil,
        cursorTrajectory: [MouseTrajectorySample] = []
    ) {
        self.timeRange = timeRange
        self.layout = layout
        self.layerMapping = layerMapping
        self.effects = effects
        self.cursorSprite = cursorSprite
        self.cursorSettings = cursorSettings
        self.cursorTrajectory = cursorTrajectory
        super.init()
    }
}
#endif
