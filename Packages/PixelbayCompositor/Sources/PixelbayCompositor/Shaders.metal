#include <metal_stdlib>
using namespace metal;

// Compositor shaders. Phase 1 had one textured-quad pass with optional
// rounded-corner alpha masking; Phase 3a adds a background pass and a
// circle-mask branch for talking-head cam framing.
//
// Coordinate conventions:
//   - Vertex input: clip-space positions in [-1, +1].
//   - Texture coordinates: [0, 1] with origin top-left (matches CVPixelBuffer
//     orientation when Metal textures are created from CVMetalTextureCache).
//   - The CPU-side pipeline emits a triangle strip whose destination rectangle
//     is already mapped to clip space.

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 layerLocal; // 0..1 inside the layer's own rect, used for SDF mask
};

// Uniforms shared across passes. Layer-local rect normalisation happens on
// the CPU side (vertex inputs). `uvOpen`/`uvClose` carry the TRUE temporal
// motion blur: the camera transform at shutter-open / shutter-close as
// source-UV remappings relative to the drawn rect (xy = scale, zw =
// offset). Identity (1,1,0,0) on both collapses to a single sample. Struct
// must stay 16-byte aligned and matched with the Swift-side mirror.
struct LayerUniforms {
    float2 outputSizePx;        // total framebuffer in pixels
    float2 layerSizePx;         // this layer's rect in pixels
    float cornerRadiusPx;       // 0 disables rounded-rect masking
    float isCircle;             // 1 → mask to inscribed circle (overrides cornerRadius)
    float opacity;              // Phase 3b talking-head crossfade — multiplies final alpha
    float screenBlurSigmaPx;    // Gaussian veil sigma in pixels; 0 = no blur
    float4 uvOpen;              // shutter-open UV remap (scale.xy, offset.zw)
    float4 uvClose;             // shutter-close UV remap (scale.xy, offset.zw)
    float4 screenCropUV;        // content-zoom source crop applied BEFORE blur (scale.xy, offset.zw); identity = full source
};

// Phase 3a background pass.
// `mode`: 0 = solid (topColor), 1 = linear gradient (top→bottom by uv.y),
//         2 = wallpaper mesh (base = topColor + radial blobs from buffer(1)).
// For mesh, `blobCount` blobs are read from a `float4` buffer at index 1, two
// float4 per blob: [color(rgb + strength), geo(x, y, radius, _)]. `aspect` is
// outputWidth/outputHeight so blobs stay circular on a wide frame.
struct BackgroundUniforms {
    float4 topColor;
    float4 bottomColor;
    float mode;
    float blobCount;
    float aspect;
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
    out.layerLocal = in.texCoord; // texCoord doubles as layer-local UV
    return out;
}

// Full-screen triangle generated from vertex ID. Covers [-1, +1]^2 with one
// triangle (no vertex buffer required).
vertex BackgroundVertexOut backgroundVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    BackgroundVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(uv.x, 1.0 - uv.y); // flip y so v=0 is top
    return out;
}

fragment float4 backgroundFragment(
    BackgroundVertexOut in [[stage_in]],
    constant BackgroundUniforms &u [[buffer(0)]],
    constant float4 *blobs [[buffer(1)]]
) {
    if (u.mode < 0.5) {
        return u.topColor;                               // solid
    }
    if (u.mode < 1.5) {
        return mix(u.topColor, u.bottomColor, in.uv.y);  // linear gradient
    }
    // Wallpaper mesh: start from the base, then blend each soft radial blob.
    float3 color = u.topColor.rgb;
    int n = int(u.blobCount + 0.5);
    for (int i = 0; i < n; i++) {
        float4 c = blobs[i * 2];        // rgb + strength
        float4 g = blobs[i * 2 + 1];    // x, y, radius, _
        // Aspect-correct x so a blob is a circle on the output, not an ellipse.
        float2 d = float2((in.uv.x - g.x) * u.aspect, in.uv.y - g.y);
        float dist = length(d);
        // 1 at the centre, smoothly to 0 at `radius`; scaled by the blob's
        // centre strength.
        float w = smoothstep(g.z, 0.0, dist) * c.a;
        color = mix(color, c.rgb, w);
    }
    return float4(color, 1.0);
}

// Rounded-rectangle SDF.
static inline float sdRoundedBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

static inline float sdCircle(float2 p, float r) {
    return length(p) - r;
}

// Layer alpha mask. 1 = fully inside, 0 = fully outside, ~1px AA transition.
// Picks circle vs rounded-rect based on the `isCircle` flag.
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

// Phase 3d Gaussian veil. 9-tap cross (center + ±σ + ±2σ on each axis).
// `sigmaPx` ≤ 0.5 short-circuits to a single sample.
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
    float2 sigmaUV = float2(
        sigmaPx / max(1.0, layerSizePx.x),
        sigmaPx / max(1.0, layerSizePx.y)
    );
    const float w0 = 1.0;
    const float w1 = 0.6065;
    const float wd = 0.3679;  // diagonals at distance σ√2 — keeps the kernel round
    const float w2 = 0.1353;
    const float wSum = w0 + 4.0 * w1 + 4.0 * wd + 4.0 * w2;
    float4 acc = tex.sample(s, uv) * w0;
    acc += tex.sample(s, uv + float2( sigmaUV.x, 0.0)) * w1;
    acc += tex.sample(s, uv + float2(-sigmaUV.x, 0.0)) * w1;
    acc += tex.sample(s, uv + float2(0.0,  sigmaUV.y)) * w1;
    acc += tex.sample(s, uv + float2(0.0, -sigmaUV.y)) * w1;
    acc += tex.sample(s, uv + float2( sigmaUV.x,  sigmaUV.y)) * wd;
    acc += tex.sample(s, uv + float2(-sigmaUV.x,  sigmaUV.y)) * wd;
    acc += tex.sample(s, uv + float2( sigmaUV.x, -sigmaUV.y)) * wd;
    acc += tex.sample(s, uv + float2(-sigmaUV.x, -sigmaUV.y)) * wd;
    acc += tex.sample(s, uv + float2( 2.0 * sigmaUV.x, 0.0)) * w2;
    acc += tex.sample(s, uv + float2(-2.0 * sigmaUV.x, 0.0)) * w2;
    acc += tex.sample(s, uv + float2(0.0,  2.0 * sigmaUV.y)) * w2;
    acc += tex.sample(s, uv + float2(0.0, -2.0 * sigmaUV.y)) * w2;
    return acc / wSum;
}

// Interleaved gradient noise (Jimenez 2014) — per-pixel tap-phase dither.
static inline float gradientNoise(float2 px) {
    return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
}

// TRUE temporal motion blur: integrate the SAME source frame under the
// camera transform interpolated from shutter-open to shutter-close —
// exactly what a physical shutter records of a moving camera over a static
// scene. The per-pixel transform delta yields directional streaks during
// pans AND radial streaks during the zoom scale change, with intensity
// derived from real camera velocity. Uniform tap weights = box shutter;
// per-pixel dithered phase kills banding. Collapses to the Gaussian veil
// path when the local delta is under a pixel (still camera).
static inline float4 temporalBlurSample(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 layerSizePx,
    float4 uvOpen,
    float4 uvClose,
    float sigmaPx,
    float2 fragPx
) {
    float2 uvA = uv * uvOpen.xy + uvOpen.zw;
    float2 uvB = uv * uvClose.xy + uvClose.zw;
    float extentPx = length((uvB - uvA) * layerSizePx);
    if (extentPx < 0.75) {
        return screenBlurSample(tex, s, uv, layerSizePx, sigmaPx);
    }
    int taps = clamp(int(extentPx / 2.0), 9, 31);
    float noise = gradientNoise(fragPx);
    float4 acc = float4(0.0);
    for (int i = 0; i < taps; ++i) {
        float t = (float(i) + noise) / float(taps);
        acc += tex.sample(s, mix(uvA, uvB, t));
    }
    return acc / float(taps);
}

// BGRA fragment: temporal/Gaussian-veiled sample, optional alpha mask.
fragment float4 bgraFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]],
    constant LayerUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Content-zoom source crop (identity for the classic path → no-op).
    float2 uvc = in.texCoord * u.screenCropUV.xy + u.screenCropUV.zw;
    float4 c = temporalBlurSample(tex, s, uvc, u.layerSizePx, u.uvOpen, u.uvClose, u.screenBlurSigmaPx, in.position.xy);
    c.a *= layerAlphaMask(in, u) * u.opacity;
    return c;
}

// Cursor pass uniforms — see MetalRenderGraph.CursorUniforms.
struct CursorUniforms {
    float2 outputSizePx;
    float2 layerSizePx;
    float2 blurOffsetUV;
    float opacity;
    float _pad0;
};

// Cursor pass. Velocity-aligned trailing shutter blur with a bright crisp
// head. `blurOffsetUV` is the distance the cursor travelled during the
// synthetic exposure; sampling uv + offset * phase integrates previous cursor
// positions behind the current pointer. clamp_to_zero because the quad is
// padded past the sprite bounds to give the trail room.
fragment float4 cursorFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]],
    constant CursorUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    float2 offset = u.blurOffsetUV;
    float minPx = min(u.layerSizePx.x, u.layerSizePx.y);
    if (length(offset) * minPx < 0.33) {
        float4 c = tex.sample(s, in.texCoord);
        c.a *= u.opacity;
        return c;
    }
    float extentPx = length(offset * u.layerSizePx);
    int taps = clamp(int(extentPx), 13, 61);
    float noise = gradientNoise(in.position.xy);
    float2 dirPx = normalize(offset * u.layerSizePx);
    float2 perpUV = float2(-dirPx.y, dirPx.x) * 0.25 / u.layerSizePx;
    float4 acc = float4(0.0);
    float wSum = 0.0;
    for (int i = 0; i < taps; ++i) {
        float phase = (float(i) + noise) / float(taps);
        float w = exp(-3.5 * phase * phase);
        float pj = fract(noise + float(i) * 0.61803398875) * 2.0 - 1.0;
        float2 uv = in.texCoord + offset * phase + perpUV * pj;
        acc += tex.sample(s, uv) * w;
        wSum += w;
    }
    acc /= wSum;
    // Sharp-head guarantee: the cursor at its true position stays ≥75% solid.
    float4 head = tex.sample(s, in.texCoord);
    acc = mix(acc, head, head.a * 0.75);
    acc.a *= u.opacity;
    return acc;
}

// NV12 fragment: samples Y (R8) + CbCr (RG8), converts BT.709 limited-range
// → sRGB. Matches what SCStream / AVCaptureVideoDataOutput deliver after
// HANDOFF iter-9 settled on NV12 / videoRange / sRGB color space.
fragment float4 nv12Fragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> yPlane [[texture(0)]],
    texture2d<float, access::sample> cbcrPlane [[texture(1)]],
    constant LayerUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Content-zoom source crop (identity for the classic path → no-op).
    float2 uvc = in.texCoord * u.screenCropUV.xy + u.screenCropUV.zw;
    float4 yAcc = temporalBlurSample(yPlane, s, uvc, u.layerSizePx, u.uvOpen, u.uvClose, u.screenBlurSigmaPx, in.position.xy);
    float4 cbcrAcc = temporalBlurSample(cbcrPlane, s, uvc, u.layerSizePx, u.uvOpen, u.uvClose, u.screenBlurSigmaPx, in.position.xy);
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
