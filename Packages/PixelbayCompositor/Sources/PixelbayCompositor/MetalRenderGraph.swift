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
    private let textureCache: CVMetalTextureCache

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
    public func render(
        layout: ResolvedLayout,
        sources: [LayerKind: CVPixelBuffer],
        destination: CVPixelBuffer
    ) throws {
        guard let screen = sources[.screen] else {
            throw RenderError.missingScreenLayer
        }
        guard let destinationTexture = makeBGRATexture(from: destination, usage: .renderTarget) else {
            throw RenderError.textureCreationFailed("destination BGRA")
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw RenderError.renderEncoderUnavailable
        }
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = destinationTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw RenderError.renderEncoderUnavailable
        }
        encoder.label = "Pixelbay.layer-pass"

        // Background pass (clear cases skip — render-target clearColor 0,0,0,1 already covered)
        drawBackground(encoder: encoder, background: layout.background)

        try drawLayer(
            encoder: encoder,
            source: screen,
            destinationRect: layout.screen,
            outputSize: layout.outputSize,
            cornerRadiusPx: layout.screenCornerRadius,
            isCircle: false,
            opacity: 1.0
        )

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
                opacity: layout.webcamOpacity
            )
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Background pass

    private struct BackgroundUniforms {
        var topColor: SIMD4<Float>
        var bottomColor: SIMD4<Float>
        var isGradient: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private func drawBackground(encoder: MTLRenderCommandEncoder, background: ResolvedBackground) {
        switch background {
        case .clear:
            // The render target's clearColor already painted black. Nothing
            // more to do for the Phase 1 look.
            return
        case .solid(let color):
            var uniforms = BackgroundUniforms(topColor: color, bottomColor: color, isGradient: 0)
            encoder.setRenderPipelineState(backgroundPipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .gradient(let top, let bottom):
            var uniforms = BackgroundUniforms(topColor: top, bottomColor: bottom, isGradient: 1)
            encoder.setRenderPipelineState(backgroundPipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
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
        var pad0: Float = 0
    }

    private func drawLayer(
        encoder: MTLRenderCommandEncoder,
        source: CVPixelBuffer,
        destinationRect: LayerRect,
        outputSize: CGSize,
        cornerRadiusPx: CGFloat,
        isCircle: Bool,
        opacity: Float
    ) throws {
        let vertices = makeQuadVertices(rect: destinationRect, outputSize: outputSize)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)

        var uniforms = LayerUniforms(
            outputSizePx: SIMD2(Float(outputSize.width), Float(outputSize.height)),
            layerSizePx: SIMD2(Float(destinationRect.size.width), Float(destinationRect.size.height)),
            cornerRadiusPx: Float(cornerRadiusPx),
            isCircle: isCircle ? 1 : 0,
            opacity: max(0, min(1, opacity))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)

        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            guard let bgraTexture = makeBGRATexture(from: source, usage: .shaderRead) else {
                throw RenderError.textureCreationFailed("BGRA source")
            }
            encoder.setRenderPipelineState(bgraPipelineState)
            encoder.setFragmentTexture(bgraTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let (yTex, cbcrTex) = makeNV12Textures(from: source) else {
                throw RenderError.textureCreationFailed("NV12 source")
            }
            encoder.setRenderPipelineState(nv12PipelineState)
            encoder.setFragmentTexture(yTex, index: 0)
            encoder.setFragmentTexture(cbcrTex, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        default:
            // Unknown pixel format — log once and skip the layer rather than
            // throwing (rendering a black frame is more useful than failing
            // the entire export). The export will still finish, the user
            // sees the missing layer and can investigate.
            log.error("unsupported source pixel format=\(String(format: "%08x", pixelFormat), privacy: .public) — skipping layer")
        }
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

    private func makeBGRATexture(from buffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
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
        guard status == kCVReturnSuccess, let textureRef else {
            log.error("BGRA texture create failed status=\(status)")
            return nil
        }
        return CVMetalTextureGetTexture(textureRef)
    }

    private func makeNV12Textures(from buffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
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
        return (yTex, cbcrTex)
    }

    // Periodic flush to release back any CVMetalTextureCache references that
    // are no longer in flight. Caller (PixelbayVideoCompositor) calls this
    // after each frame.
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
        float _pad0;
    };

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
        float4 c = tex.sample(s, in.texCoord);
        c.a *= layerAlphaMask(in, u) * u.opacity;
        return c;
    }

    fragment float4 nv12Fragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> yPlane [[texture(0)]],
        texture2d<float, access::sample> cbcrPlane [[texture(1)]],
        constant LayerUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float y = yPlane.sample(s, in.texCoord).r;
        float2 cbcr = cbcrPlane.sample(s, in.texCoord).rg;

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
