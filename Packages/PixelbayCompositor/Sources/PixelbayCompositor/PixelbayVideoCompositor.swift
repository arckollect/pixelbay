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

        if let renderGraph {
            do {
                try renderGraph.render(
                    layout: layout,
                    sources: sources,
                    destination: destination
                )
                renderGraph.flushTextureCache()
            } catch {
                log.error("render() failed: \(String(describing: error), privacy: .public)")
                // Fall through to passthrough.
                passthroughScreen(into: destination, sources: sources)
            }
        } else {
            passthroughScreen(into: destination, sources: sources)
        }

        request.finish(withComposedVideoFrame: destination)
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

    public init(
        timeRange: CMTimeRange,
        layout: ResolvedLayout,
        layerMapping: [CMPersistentTrackID: LayerKind],
        effects: [EffectKeyframe] = []
    ) {
        self.timeRange = timeRange
        self.layout = layout
        self.layerMapping = layerMapping
        self.effects = effects
        super.init()
    }
}
#endif
