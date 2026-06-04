#if canImport(Metal) && canImport(MetalKit) && canImport(CoreVideo)
import CoreVideo
import Foundation
import Metal
import MetalKit
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "MetalRenderGraph")

// One Metal render path used by both preview (AVPlayer + AVMutableVideoComposition)
// and export (AVAssetExportSession + the same composition). Per HANDOFF §6.6
// we never fork preview vs export — drift produces "looks different in export"
// bugs.
//
// Phase 1 responsibilities:
//   • Wrap source CVPixelBuffers as MTLTextures via CVMetalTextureCache (zero
//     copy where possible).
//   • Render layers in order: screen full-frame, then optional webcam overlay
//     with rounded corners.
//   • Output to a CVPixelBuffer the AVVideoCompositing adapter hands us.
//
// Phase 3a's layout / wallpaper / per-corner picker grow this with more passes;
// the per-pass pipeline-state cache below is built that way intentionally.
//
// Concurrency: AVVideoCompositing's startRequest is called on a serial queue
// (AVAsynchronousVideoCompositionRequest's compositor's videoProcessingQueue),
// so render() expects to be called on a single queue at a time. Internal
// state isn't actor-isolated — the caller's serialisation is what we rely on.
public final class MetalRenderGraph: @unchecked Sendable {
    public enum SetupError: Error {
        case noMetalDevice
        case shaderLibraryUnavailable(String)
        case pipelineStateFailed(String)
        case textureCacheFailed(CVReturn)
    }

    public enum RenderError: Error {
        case missingScreenLayer
        case textureCreationFailed(String)
        case pixelBufferLockFailed
        case renderEncoderUnavailable
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let bgraPipelineState: MTLRenderPipelineState
    private let nv12PipelineState: MTLRenderPipelineState
    private let backgroundPipelineState: MTLRenderPipelineState
    private let cursorPipelineState: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    // Cursor sprite texture cache — keyed by CGImage identity. The app
    // target hands us the same CGImage every frame (built once from
    // NSCursor.arrow), so we upload to GPU on first sight and reuse the
    // resulting MTLTexture for every subsequent draw. Cleared when the
    // identity changes (e.g. user customised their cursor mid-edit).
    private var cursorSpriteIdentity: ObjectIdentifier?
    private var cursorSpriteTexture: MTLTexture?
    private lazy var cursorTextureLoader: MTKTextureLoader = MTKTextureLoader(device: device)

    // Image-wallpaper texture cache — same idea as the cursor sprite. The
    // instruction hands us one CGImage (center-cropped to the output aspect)
    // for the whole composition, so we upload once and reuse it every frame.
    private var backgroundImageIdentity: ObjectIdentifier?
    private var backgroundImageTexture: MTLTexture?

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SetupError.noMetalDevice
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw SetupError.pipelineStateFailed("makeCommandQueue returned nil")
        }
        self.queue = queue

        // Compile shaders at runtime from an embedded source string. This
        // avoids depending on the Metal Toolchain at build time (which isn't
        // present on every dev machine and would block CI / first-time
        // contributors). The cost is ~tens of milliseconds at the first
        // MetalRenderGraph init per process — negligible for v0.1's preview
        // surface.
        //
        // The same source lives in Shaders.metal in this directory for IDE
        // syntax highlighting; the .metal file is excluded from the SwiftPM
        // build (Package.swift's `exclude:`). Keep them in sync.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SetupError.shaderLibraryUnavailable("makeLibrary(source:) failed: \(error)")
        }

        guard let vertexFunction = library.makeFunction(name: "layerVertex") else {
            throw SetupError.shaderLibraryUnavailable("layerVertex function missing")
        }
        guard let bgraFragment = library.makeFunction(name: "bgraFragment") else {
            throw SetupError.shaderLibraryUnavailable("bgraFragment function missing")
        }
        guard let nv12Fragment = library.makeFunction(name: "nv12Fragment") else {
            throw SetupError.shaderLibraryUnavailable("nv12Fragment function missing")
        }
        guard let backgroundFragment = library.makeFunction(name: "backgroundFragment") else {
            throw SetupError.shaderLibraryUnavailable("backgroundFragment function missing")
        }
        guard let backgroundVertex = library.makeFunction(name: "backgroundVertex") else {
            throw SetupError.shaderLibraryUnavailable("backgroundVertex function missing")
        }
        guard let cursorFragment = library.makeFunction(name: "cursorFragment") else {
            throw SetupError.shaderLibraryUnavailable("cursorFragment function missing")
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let bgraDescriptor = MTLRenderPipelineDescriptor()
        bgraDescriptor.label = "Pixelbay.bgra"
        bgraDescriptor.vertexFunction = vertexFunction
        bgraDescriptor.fragmentFunction = bgraFragment
        bgraDescriptor.vertexDescriptor = vertexDescriptor
        bgraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        bgraDescriptor.colorAttachments[0].isBlendingEnabled = true
        bgraDescriptor.colorAttachments[0].rgbBlendOperation = .add
        bgraDescriptor.colorAttachments[0].alphaBlendOperation = .add
        bgraDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bgraDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        bgraDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bgraDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.bgraPipelineState = try device.makeRenderPipelineState(descriptor: bgraDescriptor)
        } catch {
            throw SetupError.pipelineStateFailed("bgra: \(error)")
        }

        let nv12Descriptor = MTLRenderPipelineDescriptor()
        nv12Descriptor.label = "Pixelbay.nv12"
        nv12Descriptor.vertexFunction = vertexFunction
        nv12Descriptor.fragmentFunction = nv12Fragment
        nv12Descriptor.vertexDescriptor = vertexDescriptor
        nv12Descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        nv12Descriptor.colorAttachments[0].isBlendingEnabled = true
        nv12Descriptor.colorAttachments[0].rgbBlendOperation = .add
        nv12Descriptor.colorAttachments[0].alphaBlendOperation = .add
        nv12Descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        nv12Descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        nv12Descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        nv12Descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.nv12PipelineState = try device.makeRenderPipelineState(descriptor: nv12Descriptor)
        } catch {
            throw SetupError.pipelineStateFailed("nv12: \(error)")
        }

        // Background pass: full-screen triangle with no texture. Vertex
        // function emits clip-space coords directly; fragment picks the
        // solid color or interpolates the gradient using the y component.
        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "Pixelbay.background"
        backgroundDescriptor.vertexFunction = backgroundVertex
        backgroundDescriptor.fragmentFunction = backgroundFragment
        backgroundDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        backgroundDescriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            self.backgroundPipelineState = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        } catch {
            throw SetupError.pipelineStateFailed("background: \(error)")
        }

        // Cursor pass: same vertex format + blending as bgra, but routes
        // through `cursorFragment` so we can tap the sprite multiple times
        // along the velocity vector for motion blur.
        let cursorDescriptor = MTLRenderPipelineDescriptor()
        cursorDescriptor.label = "Pixelbay.cursor"
        cursorDescriptor.vertexFunction = vertexFunction
        cursorDescriptor.fragmentFunction = cursorFragment
        cursorDescriptor.vertexDescriptor = vertexDescriptor
        cursorDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        cursorDescriptor.colorAttachments[0].isBlendingEnabled = true
        cursorDescriptor.colorAttachments[0].rgbBlendOperation = .add
        cursorDescriptor.colorAttachments[0].alphaBlendOperation = .add
        cursorDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cursorDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        cursorDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cursorDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.cursorPipelineState = try device.makeRenderPipelineState(descriptor: cursorDescriptor)
        } catch {
            throw SetupError.pipelineStateFailed("cursor: \(error)")
        }

        var textureCacheRef: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCacheRef)
        guard cacheStatus == kCVReturnSuccess, let textureCache = textureCacheRef else {
            throw SetupError.textureCacheFailed(cacheStatus)
        }
        self.textureCache = textureCache
        log.info("MetalRenderGraph initialised device=\(device.name, privacy: .public)")
    }

    // Render the ResolvedLayout into `destination`, sourcing pixels from
    // `sources`. `destination` must be a BGRA CVPixelBuffer matching the
    // layout's outputSize. Missing layers (e.g. webcam disabled) are skipped.
    //
    // `cursorSprite` + `cursorState` together drive the Phase 3c synthetic
    // cursor pass. Both nil = no cursor (legacy assets, cursor disabled,
    // or no trajectory available at this frame). The cursor pass runs
    // AFTER the screen and BEFORE the webcam so the cursor always appears
    // above the screen content but below the talking-head cam — matches
    // the layer order convention for screencast tools (cursor is part of
    // the "screen story", cam is the presenter).
    //
    // `completion` fires on a Metal-internal thread once the GPU has
    // finished executing this frame's command buffer. The caller is
    // expected to call `request.finish(withComposedVideoFrame:)` (or its
    // equivalent) from inside the handler — synchronously returning from
    // `render` would leave the destination buffer in an indeterminate
    // state. The earlier `waitUntilCompleted` design serialized CPU and
    // GPU on this serial render queue, capping throughput at 1/(cpu+gpu)
    // per frame; the async-commit design pipelines them, so CPU encoding
    // of frame N+1 overlaps with GPU work on frame N.
    public func render(
        layout: ResolvedLayout,
        sources: [LayerKind: CVPixelBuffer],
        destination: CVPixelBuffer,
        backgroundImage: CGImage? = nil,
        cursorSprite: CursorSpriteData? = nil,
        cursorState: CursorRenderState? = nil,
        completion: @escaping @Sendable () -> Void
    ) throws {
        guard let screen = sources[.screen] else {
            throw RenderError.missingScreenLayer
        }
        guard let destinationPair = makeBGRATexture(from: destination, usage: .renderTarget) else {
            throw RenderError.textureCreationFailed("destination BGRA")
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw RenderError.renderEncoderUnavailable
        }

        // CVMetalTexture refs the command buffer's MTLTextures are
        // backed by — keep them alive until the GPU finishes (captured
        // by the completed handler below). Without this, the cache may
        // evict an in-flight CVMetalTexture between commit and GPU
        // completion, leaving the encoder reading freed memory.
        var cvTextureRefs: [CVMetalTexture] = [destinationPair.0]

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = destinationPair.1
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw RenderError.renderEncoderUnavailable
        }
        encoder.label = "Pixelbay.layer-pass"

        // Background pass (clear cases skip — render-target clearColor 0,0,0,1 already covered)
        let bgAspect = layout.outputSize.height > 0
            ? Float(layout.outputSize.width / layout.outputSize.height)
            : 1
        // Image wallpapers: the CGImage is already center-cropped to the output
        // aspect, so a full-screen draw is aspect-fill with no distortion. The
        // texture is cached by image identity (like the cursor sprite). If the
        // image is missing (decode failed) we fall through to the solid fallback.
        if case .image = layout.background,
           let backgroundImage,
           let bgTexture = backgroundTexture(for: backgroundImage) {
            drawBackgroundImage(encoder: encoder, texture: bgTexture, outputSize: layout.outputSize)
        } else {
            drawBackground(encoder: encoder, background: layout.background, aspect: bgAspect)
        }

        try drawLayer(
            encoder: encoder,
            source: screen,
            destinationRect: layout.screen,
            outputSize: layout.outputSize,
            cornerRadiusPx: layout.screenCornerRadius,
            isCircle: false,
            opacity: 1.0,
            screenBlurSigmaPx: layout.screenZoomBlurSigmaPx,
            cvTextureRefs: &cvTextureRefs
        )

        if let cursorSprite, let cursorState {
            drawCursor(
                encoder: encoder,
                sprite: cursorSprite,
                state: cursorState,
                screen: layout.screen,
                outputSize: layout.outputSize
            )
        }

        if let webcamRect = layout.webcam, let webcam = sources[.webcam] {
            let isCircle = layout.webcamShape == .circle
            let radius: CGFloat
            if isCircle {
                radius = min(webcamRect.size.width, webcamRect.size.height) / 2
            } else {
                radius = layout.webcamCornerRadius
            }
            try drawLayer(
                encoder: encoder,
                source: webcam,
                destinationRect: webcamRect,
                outputSize: layout.outputSize,
                cornerRadiusPx: radius,
                isCircle: isCircle,
                opacity: layout.webcamOpacity,
                cvTextureRefs: &cvTextureRefs
            )
        }

        encoder.endEncoding()
        // Capture refs by value into the closure so they survive past
        // `render()`'s return. The closure fires on Metal's internal
        // queue when the GPU finishes — `cvTextureRefs` is released
        // there, not on the render queue, which is what lets the
        // render queue process frame N+1's CPU encoding while frame N
        // is still on the GPU. CVMetalTexture is a CF type that isn't
        // formally Sendable, but we treat each element as immutable
        // for the closure's lifetime; the wrapper makes that explicit
        // for Swift 6's checked-Sendable closure analysis.
        let heldRefs = SendableTextureRefs(refs: cvTextureRefs)
        commandBuffer.addCompletedHandler { _ in
            _ = heldRefs
            completion()
        }
        commandBuffer.commit()
    }

    /// Holds CVMetalTexture refs across an `addCompletedHandler` boundary
    /// so they outlive `render()` and keep their backing CVPixelBuffer
    /// alive until the GPU finishes. The `@unchecked` is safe because
    /// each ref is treated as immutable — the wrapper has no public API
    /// to mutate the underlying array, and the closure that owns it
    /// only reads it (and then releases when the closure deallocates).
    private struct SendableTextureRefs: @unchecked Sendable {
        let refs: [CVMetalTexture]
    }

    // MARK: - Background pass

    // Matches `BackgroundUniforms` in Shaders.metal (two float4 + four float =
    // 48 bytes, 16-aligned). `mode`: 0 solid, 1 linear gradient, 2 mesh.
    private struct BackgroundUniforms {
        var topColor: SIMD4<Float>
        var bottomColor: SIMD4<Float>
        var mode: Float
        var blobCount: Float = 0
        var aspect: Float = 1
        var pad2: Float = 0
    }

    private func drawBackground(
        encoder: MTLRenderCommandEncoder,
        background: ResolvedBackground,
        aspect: Float
    ) {
        // The render target's clearColor already painted black, so the Phase 1
        // `.clear` look needs no pass at all.
        if case .clear = background { return }

        var uniforms: BackgroundUniforms
        // Interleaved [color, geo] per mesh blob bound at buffer(1). The
        // fragment function always references buffer(1), so even solid/gradient
        // must bind a (1-element) dummy or Metal errors on the draw; `mode`
        // and `blobCount` keep the shader from actually reading it.
        var blobData: [SIMD4<Float>] = [SIMD4<Float>(repeating: 0)]

        switch background {
        case .clear:
            return  // handled above; keeps the switch exhaustive
        case .solid(let color):
            uniforms = BackgroundUniforms(topColor: color, bottomColor: color, mode: 0)
        case .gradient(let top, let bottom):
            uniforms = BackgroundUniforms(topColor: top, bottomColor: bottom, mode: 1)
        case .mesh(let base, let blobs):
            uniforms = BackgroundUniforms(
                topColor: base,
                bottomColor: base,
                mode: 2,
                blobCount: Float(blobs.count),
                aspect: aspect
            )
            if !blobs.isEmpty {
                blobData = blobs.flatMap { [$0.color, $0.geo] }
            }
        case .image(let fallback):
            // Reached only when the image buffer was missing (render() draws
            // the buffer itself when present). Paint the flat fallback.
            uniforms = BackgroundUniforms(topColor: fallback, bottomColor: fallback, mode: 0)
        }

        encoder.setRenderPipelineState(backgroundPipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
        encoder.setFragmentBytes(
            &blobData,
            length: blobData.count * MemoryLayout<SIMD4<Float>>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Upload (and cache) the wallpaper image to a texture, keyed by CGImage
    /// identity — mirrors the cursor-sprite cache. Same `MTKTextureLoader`
    /// path, so orientation matches the cursor (CGImage top-down → sampled
    /// with `makeQuadVertices`' texCoord(0,0)=top-left).
    private func backgroundTexture(for image: CGImage) -> MTLTexture? {
        let identity = ObjectIdentifier(image)
        if backgroundImageIdentity != identity || backgroundImageTexture == nil {
            do {
                backgroundImageTexture = try cursorTextureLoader.newTexture(
                    cgImage: image,
                    options: [
                        .SRGB: false,
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                    ]
                )
                backgroundImageIdentity = identity
            } catch {
                log.error("background image texture upload failed: \(String(describing: error), privacy: .public)")
                backgroundImageTexture = nil
                backgroundImageIdentity = nil
                return nil
            }
        }
        return backgroundImageTexture
    }

    /// Draw the wallpaper texture full-screen (BGRA pipeline). The image is
    /// pre-cropped to the output aspect, so a 0…1 texCoord fill is aspect-fill.
    private func drawBackgroundImage(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        outputSize: CGSize
    ) {
        let fullRect = LayerRect(origin: .zero, size: outputSize)
        let vertices = makeQuadVertices(rect: fullRect, outputSize: outputSize)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
        var uniforms = LayerUniforms(
            outputSizePx: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            layerSizePx: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            cornerRadiusPx: 0,
            isCircle: 0,
            opacity: 1
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setRenderPipelineState(bgraPipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Per-layer draw

    private struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    private struct LayerUniforms {
        var outputSizePx: SIMD2<Float>
        var layerSizePx: SIMD2<Float>
        var cornerRadiusPx: Float
        var isCircle: Float
        var opacity: Float
        var screenBlurSigmaPx: Float = 0
        // 8-byte tail padding so this struct matches the Metal-side layout
        // (Metal aligns to 16 bytes; without this the next struct field
        // would land in the wrong slot when the buffer is reused).
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
        var pad3: Float = 0
    }

    /// Cursor-specific uniforms. Adds a velocity offset (in cursor-UV space)
    /// that the shader uses to sample multiple taps along the motion vector
    /// for a soft motion-blur look. Zero offset collapses the kernel back to
    /// a single sample, so a stationary cursor renders crisp.
    private struct CursorUniforms {
        var outputSizePx: SIMD2<Float>
        var layerSizePx: SIMD2<Float>
        var blurOffsetUV: SIMD2<Float>
        var opacity: Float
        var pad0: Float = 0
    }

    private func drawLayer(
        encoder: MTLRenderCommandEncoder,
        source: CVPixelBuffer,
        destinationRect: LayerRect,
        outputSize: CGSize,
        cornerRadiusPx: CGFloat,
        isCircle: Bool,
        opacity: Float,
        screenBlurSigmaPx: Float = 0,
        cvTextureRefs: inout [CVMetalTexture]
    ) throws {
        let vertices = makeQuadVertices(rect: destinationRect, outputSize: outputSize)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)

        var uniforms = LayerUniforms(
            outputSizePx: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            layerSizePx: SIMD2(Float(destinationRect.size.width), Float(destinationRect.size.height)),
            cornerRadiusPx: Float(cornerRadiusPx),
            isCircle: isCircle ? 1 : 0,
            opacity: max(0, min(1, opacity)),
            screenBlurSigmaPx: max(0, screenBlurSigmaPx)
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)

        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let pair = makeBGRATexture(from: source, usage: .shaderRead) else {
                throw RenderError.textureCreationFailed("BGRA source")
            }
            cvTextureRefs.append(pair.0)
            encoder.setRenderPipelineState(bgraPipelineState)
            encoder.setFragmentTexture(pair.1, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let pair = makeNV12Textures(from: source) else {
                throw RenderError.textureCreationFailed("NV12 source")
            }
            cvTextureRefs.append(pair.yRef)
            cvTextureRefs.append(pair.cbcrRef)
            encoder.setRenderPipelineState(nv12PipelineState)
            encoder.setFragmentTexture(pair.yTexture, index: 0)
            encoder.setFragmentTexture(pair.cbcrTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        default:
            // Unknown pixel format — log once and skip the layer rather than
            // throwing (rendering a black frame is more useful than failing
            // the entire export). The export will still finish, the user
            // sees the missing layer and can investigate.
            log.error("unsupported source pixel format=\(String(format: "%08x", pixelFormat), privacy: .public) — skipping layer")
        }
    }

    // MARK: - Cursor pass (Phase 3c)

    /// Base output-height fraction the cursor occupies at `scale = 1.0`.
    /// At 1080p output a scale-1.0 cursor renders ~32 px tall; the
    /// `CursorSettings.default.scale` of 3.25 yields ~104 px — visibly
    /// larger than the OS cursor (~16 px on standard DPI) so a viewer
    /// can track it without straining at typical screencast playback
    /// sizes. Cursor aspect ratio is preserved from `pointSize`, so a
    /// taller/wider sprite scales proportionally.
    private static let cursorBaseFractionOfOutputHeight: CGFloat = 32.0 / 1080.0

    private func drawCursor(
        encoder: MTLRenderCommandEncoder,
        sprite: CursorSpriteData,
        state: CursorRenderState,
        screen: LayerRect,
        outputSize: CGSize
    ) {
        // Cursor position in output pixels: anchor at the screen rect (so
        // zoom transforms move the cursor automatically, since the screen
        // rect has already been zoomed by EffectEvaluator) using the
        // recorded normalised fraction as the content coordinate inside
        // that rect.
        let cursorX = screen.minX + CGFloat(state.xFractionInScreen) * screen.size.width
        let cursorY = screen.minY + CGFloat(state.yFractionInScreen) * screen.size.height

        // Cursor size in output pixels — keep the sprite's intrinsic
        // aspect ratio so the arrow doesn't squash on non-square sprites.
        let pointSize = sprite.pointSize
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        let scale = max(0.0, CGFloat(state.scale))
        let heightPx = scale * Self.cursorBaseFractionOfOutputHeight * outputSize.height
        let widthPx = heightPx * (pointSize.width / pointSize.height)
        guard widthPx > 0.5, heightPx > 0.5 else { return }

        // Hot-spot offset, in output pixels. NSCursor.hotSpot is in image
        // points (top-left origin); convert to a fraction of pointSize
        // first, then multiply by the rendered size so the hot spot lands
        // exactly on (cursorX, cursorY) regardless of scale.
        let hotSpotFractionX = sprite.hotSpot.x / pointSize.width
        let hotSpotFractionY = sprite.hotSpot.y / pointSize.height
        let originX = cursorX - hotSpotFractionX * widthPx
        let originY = cursorY - hotSpotFractionY * heightPx

        let rect = LayerRect(
            origin: CGPoint(x: originX, y: originY),
            size: CGSize(width: widthPx, height: heightPx)
        )

        // Upload sprite to GPU on first sight (or when identity changes).
        // CGImage is a CF type — `ObjectIdentifier` of the bridged class
        // gives a stable identity for the lifetime of the CGImage.
        let identity = ObjectIdentifier(sprite.cgImage)
        if cursorSpriteIdentity != identity || cursorSpriteTexture == nil {
            do {
                cursorSpriteTexture = try cursorTextureLoader.newTexture(
                    cgImage: sprite.cgImage,
                    options: [
                        .SRGB: false,
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                    ]
                )
                cursorSpriteIdentity = identity
            } catch {
                log.error("cursor texture upload failed: \(String(describing: error), privacy: .public)")
                cursorSpriteTexture = nil
                cursorSpriteIdentity = nil
                return
            }
        }
        guard let texture = cursorSpriteTexture else { return }

        let vertices = makeQuadVertices(rect: rect, outputSize: outputSize)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)

        // Convert cursor velocity (screen-content fraction per second) into
        // a blur offset in cursor-UV space. The chain:
        //   velocity * shutterTime          → fraction of screen-content traversed during the shutter
        //   * screen.size.width / widthPx   → fraction of the cursor sprite width that maps to
        //
        // `shutterTime` is the synthetic motion-blur exposure window. 1/120 s
        // is a half-frame at 60 fps, so the trail length is a hint of
        // sub-frame motion rather than a full inter-frame streak. Was 1/30 s
        // originally, then 1/60 s, now 1/120 s after user feedback that fast
        // sweeps still read as a "blur smear moving across the screen"
        // rather than a recognizable cursor with a small motion trail. The
        // kernel is also clamped tighter (±0.15 UV, down from ±0.3) so even
        // at saturation the cursor sprite stays clearly identifiable.
        let shutterTime: CGFloat = 1.0 / 120.0
        let traversedXContent = CGFloat(state.velocityXFractionPerSecond) * shutterTime * screen.size.width
        let traversedYContent = CGFloat(state.velocityYFractionPerSecond) * shutterTime * screen.size.height
        let blurOffsetUVX = clampUV(Float(traversedXContent / widthPx))
        let blurOffsetUVY = clampUV(Float(traversedYContent / heightPx))

        var uniforms = CursorUniforms(
            outputSizePx: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            layerSizePx: SIMD2(Float(widthPx), Float(heightPx)),
            blurOffsetUV: SIMD2(blurOffsetUVX, blurOffsetUVY),
            opacity: 1.0
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CursorUniforms>.stride, index: 0)
        encoder.setRenderPipelineState(cursorPipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func clampUV(_ v: Float) -> Float {
        // ±0.15 of the cursor sprite UV — caps the kernel-tap spread so the
        // sprite shape stays readable on saturation. Was ±0.5 originally,
        // then ±0.3; tightened further after user feedback that fast sweeps
        // still read as a smear, with the goal of "legible cursor + small
        // trail" rather than a moving blob. The taps still stay inside
        // `address::clamp_to_edge` territory, so no wrap-side garbage leaks.
        max(-0.15, min(0.15, v))
    }

    // Triangle-strip quad covering destinationRect in clip space (-1..+1).
    // Vertex order: top-left, top-right, bottom-left, bottom-right.
    // Texture coords use top-left origin to match CVPixelBuffer / Metal
    // conventions.
    private func makeQuadVertices(rect: LayerRect, outputSize: CGSize) -> [Vertex] {
        // Clip-space mapping: x = 2*nx - 1, y = 1 - 2*ny  (Y flipped because
        // CVPixelBuffer is top-left origin but Metal clip space is +Y up).
        let nMinX = Float(rect.minX / outputSize.width)
        let nMaxX = Float(rect.maxX / outputSize.width)
        let nMinY = Float(rect.minY / outputSize.height)
        let nMaxY = Float(rect.maxY / outputSize.height)
        let clipMinX = nMinX * 2 - 1
        let clipMaxX = nMaxX * 2 - 1
        let clipMaxY = 1 - nMinY * 2     // top
        let clipMinY = 1 - nMaxY * 2     // bottom
        return [
            Vertex(position: SIMD2(clipMinX, clipMaxY), texCoord: SIMD2(0, 0)), // top-left
            Vertex(position: SIMD2(clipMaxX, clipMaxY), texCoord: SIMD2(1, 0)), // top-right
            Vertex(position: SIMD2(clipMinX, clipMinY), texCoord: SIMD2(0, 1)), // bottom-left
            Vertex(position: SIMD2(clipMaxX, clipMinY), texCoord: SIMD2(1, 1))  // bottom-right
        ]
    }

    // Returns the CVMetalTexture ref alongside the MTLTexture so the
    // caller can keep the bridge alive until the GPU command buffer
    // completes — without this, the cache may evict an in-flight ref
    // and leave the encoder reading freed memory under the async-commit
    // path.
    private func makeBGRATexture(from buffer: CVPixelBuffer, usage: MTLTextureUsage) -> (CVMetalTexture, MTLTexture)? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef,
              let mtl = CVMetalTextureGetTexture(textureRef) else {
            log.error("BGRA texture create failed status=\(status)")
            return nil
        }
        return (textureRef, mtl)
    }

    private struct NV12TexturePair {
        let yRef: CVMetalTexture
        let cbcrRef: CVMetalTexture
        let yTexture: MTLTexture
        let cbcrTexture: MTLTexture
    }

    private func makeNV12Textures(from buffer: CVPixelBuffer) -> NV12TexturePair? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var yRef: CVMetalTexture?
        var cbcrRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &yRef
        )
        let cbcrStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,
            &cbcrRef
        )
        guard yStatus == kCVReturnSuccess, cbcrStatus == kCVReturnSuccess,
              let yRef, let cbcrRef,
              let yTex = CVMetalTextureGetTexture(yRef),
              let cbcrTex = CVMetalTextureGetTexture(cbcrRef) else {
            log.error("NV12 texture create failed yStatus=\(yStatus) cbcrStatus=\(cbcrStatus)")
            return nil
        }
        return NV12TexturePair(yRef: yRef, cbcrRef: cbcrRef, yTexture: yTex, cbcrTexture: cbcrTex)
    }

    // Periodic flush to release CVMetalTextureCache references that are
    // no longer in flight. Under the async-commit path this is NOT
    // called per-frame anymore (the completion-handler closure pins refs
    // for the in-flight frame; the cache recycles older entries on its
    // own). Kept on the public surface in case a caller wants explicit
    // control during teardown — invoking it while a frame is in flight
    // is safe because the closure's strong refs keep that frame's
    // CVMetalTextures alive past the flush.
    public func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // Compiled at first init via makeLibrary(source:). Keep in sync with
    // Shaders.metal (which exists for IDE syntax highlighting only and is
    // excluded from the SwiftPM build).
    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 texCoord [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float2 layerLocal;
    };

    struct LayerUniforms {
        float2 outputSizePx;
        float2 layerSizePx;
        float cornerRadiusPx;
        float isCircle;
        float opacity;
        float screenBlurSigmaPx;
        float _pad0;
        float _pad1;
        float _pad2;
        float _pad3;
    };

    // Phase 3d screen blur. Approximate Gaussian as a 9-tap cross
    // (center + ±σ in 4 directions + ±2σ in 4 directions). Cheaper than
    // separable two-pass for the subtle (≤ 3 px) sigmas we use, and
    // visually indistinguishable since the kernel is small. `sigmaPx`
    // ≤ 0.5 short-circuits to a single sample so held-zoom frames stay
    // bit-identical to a no-blur pass.
    static inline float4 screenBlurSample(
        texture2d<float, access::sample> tex,
        sampler s,
        float2 uv,
        float2 layerSizePx,
        float sigmaPx
    ) {
        if (sigmaPx <= 0.5) {
            return tex.sample(s, uv);
        }
        // Sigma normalised against the layer's pixel size so the kernel
        // is symmetric in pixels regardless of viewport aspect ratio.
        float2 sigmaUV = float2(
            sigmaPx / max(1.0, layerSizePx.x),
            sigmaPx / max(1.0, layerSizePx.y)
        );
        // Gaussian weights at distances 0, 1σ, 2σ.
        const float w0 = 1.0;
        const float w1 = 0.6065;  // exp(-0.5)
        const float w2 = 0.1353;  // exp(-2.0)
        const float wSum = w0 + 4.0 * w1 + 4.0 * w2;
        float4 acc = tex.sample(s, uv) * w0;
        acc += tex.sample(s, uv + float2( sigmaUV.x, 0.0)) * w1;
        acc += tex.sample(s, uv + float2(-sigmaUV.x, 0.0)) * w1;
        acc += tex.sample(s, uv + float2(0.0,  sigmaUV.y)) * w1;
        acc += tex.sample(s, uv + float2(0.0, -sigmaUV.y)) * w1;
        acc += tex.sample(s, uv + float2( 2.0 * sigmaUV.x, 0.0)) * w2;
        acc += tex.sample(s, uv + float2(-2.0 * sigmaUV.x, 0.0)) * w2;
        acc += tex.sample(s, uv + float2(0.0,  2.0 * sigmaUV.y)) * w2;
        acc += tex.sample(s, uv + float2(0.0, -2.0 * sigmaUV.y)) * w2;
        return acc / wSum;
    }

    struct BackgroundUniforms {
        float4 topColor;
        float4 bottomColor;
        float isGradient;
        float _pad0;
        float _pad1;
        float _pad2;
    };

    struct BackgroundVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut layerVertex(VertexIn in [[stage_in]]) {
        VertexOut out;
        out.position = float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        out.layerLocal = in.texCoord;
        return out;
    }

    // Full-screen triangle (Saschka Willems / standard trick). Vertex IDs
    // 0/1/2 produce a triangle that covers the [-1,+1]^2 viewport.
    vertex BackgroundVertexOut backgroundVertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        BackgroundVertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(uv.x, 1.0 - uv.y);
        return out;
    }

    fragment float4 backgroundFragment(
        BackgroundVertexOut in [[stage_in]],
        constant BackgroundUniforms &u [[buffer(0)]]
    ) {
        if (u.isGradient > 0.5) {
            return mix(u.topColor, u.bottomColor, in.uv.y);
        }
        return u.topColor;
    }

    static inline float sdRoundedBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }

    static inline float sdCircle(float2 p, float r) {
        return length(p) - r;
    }

    static inline float layerAlphaMask(VertexOut in, constant LayerUniforms &u) {
        float2 layerPx = (in.layerLocal - 0.5) * u.layerSizePx;
        float d;
        if (u.isCircle > 0.5) {
            float r = min(u.layerSizePx.x, u.layerSizePx.y) * 0.5;
            d = sdCircle(layerPx, r);
        } else if (u.cornerRadiusPx > 0.5) {
            d = sdRoundedBox(layerPx, u.layerSizePx * 0.5, u.cornerRadiusPx);
        } else {
            return 1.0;
        }
        return saturate(0.5 - d);
    }

    fragment float4 bgraFragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> tex [[texture(0)]],
        constant LayerUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = screenBlurSample(tex, s, in.texCoord, u.layerSizePx, u.screenBlurSigmaPx);
        c.a *= layerAlphaMask(in, u) * u.opacity;
        return c;
    }

    struct CursorUniforms {
        float2 outputSizePx;
        float2 layerSizePx;
        float2 blurOffsetUV;
        float opacity;
        float _pad0;
    };

    // Cursor pass. Multi-tap motion blur aligned to the velocity vector:
    // a stationary cursor (blurOffsetUV == 0) reduces to a single sample,
    // which is bit-identical to the old bgraFragment-on-cursor path. A
    // fast-moving cursor reads as a soft streak along the motion vector.
    // 9 taps with triangular weighting — cheap (one sprite is tiny) and
    // enough to avoid step-banding at moderate kernel sizes.
    fragment float4 cursorFragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> tex [[texture(0)]],
        constant CursorUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 offset = u.blurOffsetUV;
        // Cheap escape hatch: if velocity is small enough that the kernel
        // collapses below a third of a texel, skip the taps entirely.
        float minPx = min(u.layerSizePx.x, u.layerSizePx.y);
        if (length(offset) * minPx < 0.33) {
            float4 c = tex.sample(s, in.texCoord);
            c.a *= u.opacity;
            return c;
        }
        // 9 symmetric taps at i ∈ {-4..+4}/4, triangular weights 1,2,3,4,5,4,3,2,1.
        // Symmetric around the cursor position so the rendered cursor stays
        // anchored to its reported (x,y) rather than drifting in the motion
        // direction.
        const int N = 9;
        const float weights[9] = {1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 3.0, 2.0, 1.0};
        float weightSum = 25.0; // 1+2+3+4+5+4+3+2+1
        float4 acc = float4(0.0);
        for (int i = 0; i < N; ++i) {
            float u_i = (float(i) - 4.0) / 4.0; // [-1, 1]
            float2 uv = in.texCoord + offset * u_i;
            acc += tex.sample(s, uv) * weights[i];
        }
        acc /= weightSum;
        acc.a *= u.opacity;
        return acc;
    }

    fragment float4 nv12Fragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> yPlane [[texture(0)]],
        texture2d<float, access::sample> cbcrPlane [[texture(1)]],
        constant LayerUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        // NV12 lives on two planes — Gaussian blur on each plane
        // independently and then YCbCr→RGB on the averaged result.
        // Sampling YCbCr first and then averaging the RGB conversions
        // would amplify quantisation error around chroma boundaries;
        // averaging in YCbCr space is exactly the right place since both
        // planes share the same UV.
        float4 yAcc = screenBlurSample(yPlane, s, in.texCoord, u.layerSizePx, u.screenBlurSigmaPx);
        float4 cbcrAcc = screenBlurSample(cbcrPlane, s, in.texCoord, u.layerSizePx, u.screenBlurSigmaPx);
        float y = yAcc.r;
        float2 cbcr = cbcrAcc.rg;

        float yLin = (y - 16.0/255.0) * (255.0/219.0);
        float cb = cbcr.r - 0.5;
        float cr = cbcr.g - 0.5;
        float r = yLin + 1.5748 * cr;
        float g = yLin - 0.1873 * cb - 0.4681 * cr;
        float b = yLin + 1.8556 * cb;
        float4 c = float4(saturate(r), saturate(g), saturate(b), 1.0);

        c.a *= layerAlphaMask(in, u) * u.opacity;
        return c;
    }
    """
}
#endif
