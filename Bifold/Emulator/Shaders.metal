//
//  Shaders.metal
//  Bifold
//
//  Fullscreen quad; the fragment shader samples a 256×192 screen texture.
//  filter: 0 = none (nearest), 1 = CRT scanlines, 2 = pixel grid,
//          4 = xBR (edge-directed upscale).
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 quadScale;     // NDC scale of the quad (1,1 == fill the view)
    float2 textureSize;   // 256, 192
    float2 outputSize;    // on-screen pixels covered by the quad
    int    filter;
    float  opacity;
    int    rotation;      // 0 upright, 1 book righty (CCW), 2 book lefty (CW)
    int    padding;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut bifold_vertex(uint vid [[vertex_id]],
                               constant Uniforms& u [[buffer(0)]]) {
    // Two triangles covering [-1,1]^2, scaled to the letterboxed quad.
    float2 corners[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    float2 p = corners[vid];
    VertexOut out;
    out.position = float4(p * u.quadScale, 0, 1);
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    // Book mode: the view shows the DS frame turned 90°, so sample rotated.
    if (u.rotation == 1) {
        uv = float2(1.0 - uv.y, uv.x);
    } else if (u.rotation == 2) {
        uv = float2(uv.y, 1.0 - uv.x);
    }
    out.uv = uv;
    return out;
}

static inline float4 tex_nearest(texture2d<float> tex, float2 uv) {
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    return tex.sample(s, uv);
}

static inline float4 tex_linear(texture2d<float> tex, float2 uv) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return tex.sample(s, uv);
}

/// Sharp-bilinear: nearest-neighbour crispness with a one-output-pixel
/// bilinear transition at texel edges, so pixels stay square without the
/// shimmer of pure nearest at non-integer scales.
static float4 sharp_bilinear(texture2d<float> tex, float2 uv, float2 texSize, float2 outSize) {
    float2 scale = max(outSize / texSize, float2(1.0, 1.0));
    float2 pos = uv * texSize - 0.5;
    float2 base = floor(pos);
    float2 f = pos - base;
    float2 fs = clamp((f - 0.5) * scale + 0.5, 0.0, 1.0);
    return tex_linear(tex, (base + 0.5 + fs) / texSize);
}

// ---- xBR (level 2, no-blend) — after Hyllian's xBR-lv2 shader -------------
// Edge-directed upscaler: for each output pixel it looks at a 5×5 texel
// neighbourhood, decides whether an edge passes diagonally through the texel
// and, if so, which neighbour's colour the output pixel should take.

static inline float xbr_luma(float3 c) {
    // Y weights (0.299, 0.587, 0.114) × 48, as in the original shader.
    return dot(c, float3(14.352, 28.176, 5.472));
}
static inline float4 xbr_df(float4 a, float4 b) { return abs(a - b); }
static inline float4 xbr_wd(float4 a, float4 b, float4 c, float4 d,
                            float4 e, float4 f, float4 g, float4 h) {
    return xbr_df(a, b) + xbr_df(a, c) + xbr_df(d, e) + xbr_df(d, f) + 4.0 * xbr_df(g, h);
}

static float4 xbr(texture2d<float> tex, float2 uv, float2 texSize) {
    float2 texel = 1.0 / texSize;
    float2 pos = uv * texSize;
    float2 base = floor(pos);
    float2 fp = pos - base;
    float2 c0 = (base + 0.5) * texel;
    #define XP(x, y) tex_nearest(tex, c0 + float2(x, y) * texel).rgb
    float3 A1 = XP(-1, -2), B1 = XP(0, -2), C1 = XP(1, -2);
    float3 A0 = XP(-2, -1), A = XP(-1, -1), B = XP(0, -1), C = XP(1, -1), C4 = XP(2, -1);
    float3 D0 = XP(-2,  0), D = XP(-1,  0), E = XP(0,  0), F = XP(1,  0), F4 = XP(2,  0);
    float3 G0 = XP(-2,  1), G = XP(-1,  1), H = XP(0,  1), I = XP(1,  1), I4 = XP(2,  1);
    float3 G5 = XP(-1,  2), H5 = XP(0,  2), I5 = XP(1,  2);
    #undef XP

    // Lumas arranged for the four rotations of the pattern (see original).
    float4 b  = float4(xbr_luma(B), xbr_luma(D), xbr_luma(H), xbr_luma(F));
    float4 c  = float4(xbr_luma(C), xbr_luma(A), xbr_luma(G), xbr_luma(I));
    float4 d  = b.yzwx;
    float4 e  = float4(xbr_luma(E));
    float4 f  = b.wxyz;
    float4 g  = c.zwxy;
    float4 h  = b.zwxy;
    float4 i  = c.wxyz;
    float4 i4 = float4(xbr_luma(I4), xbr_luma(C1), xbr_luma(A0), xbr_luma(G5));
    float4 i5 = float4(xbr_luma(I5), xbr_luma(C4), xbr_luma(A1), xbr_luma(G0));
    float4 h5 = float4(xbr_luma(H5), xbr_luma(F4), xbr_luma(B1), xbr_luma(D0));
    float4 f4 = h5.yzwx;

    // Lines below which interpolation happens, for each rotation.
    const float4 Ao = float4(1.0, -1.0, -1.0,  1.0), Bo = float4(1.0,  1.0, -1.0, -1.0), Co = float4(1.5, 0.5, -0.5, 0.5);
    const float4 Ax = float4(1.0, -1.0, -1.0,  1.0), Bx = float4(0.5,  2.0, -0.5, -2.0), Cx = float4(1.0, 1.0, -0.5, 0.0);
    const float4 Ay = float4(1.0, -1.0, -1.0,  1.0), By = float4(2.0,  0.5, -2.0, -0.5), Cy = float4(2.0, 0.0, -1.0, 0.5);
    bool4 fx      = (Ao * fp.y + Bo * fp.x) > Co;
    bool4 fx_left = (Ax * fp.y + Bx * fp.x) > Cx;
    bool4 fx_up   = (Ay * fp.y + By * fp.x) > Cy;

    bool4 r1  = (e != f) & (e != h);
    bool4 r2l = (e != g) & (d != g);
    bool4 r2u = (e != c) & (b != c);

    bool4 edr      = (xbr_wd(e, c, g, i, h5, f4, h, f) < xbr_wd(h, d, i5, f, i4, b, e, i)) & r1;
    bool4 edr_left = ((2.0 * xbr_df(f, g)) <= xbr_df(h, c)) & r2l;
    bool4 edr_up   = (xbr_df(f, g) >= (2.0 * xbr_df(h, c))) & r2u;

    bool4 nc = edr & (fx | (edr_left & fx_left) | (edr_up & fx_up));
    bool4 px = xbr_df(e, f) <= xbr_df(e, h);

    float3 res = nc.x ? (px.x ? F : H)
               : nc.y ? (px.y ? B : F)
               : nc.z ? (px.z ? D : B)
               : nc.w ? (px.w ? H : D)
               : E;
    return float4(res, 1.0);
}

fragment float4 bifold_fragment(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                constant Uniforms& u [[buffer(0)]]) {
    float4 color;
    if (u.filter == 4) {
        color = xbr(tex, in.uv, u.textureSize);
    } else if (u.filter == 5) {
        color = sharp_bilinear(tex, in.uv, u.textureSize, u.outputSize);
    } else {
        color = tex_nearest(tex, in.uv);
    }

    if (u.filter == 1) {
        // CRT: darken every other emulated scanline, with a soft phosphor feel.
        float line = in.uv.y * u.textureSize.y;
        float scan = 0.5 + 0.5 * cos(line * 2.0 * M_PI_F);
        float darken = mix(0.68, 1.0, scan);
        // Subtle horizontal bleed.
        float2 texel = 1.0 / u.textureSize;
        float4 l = tex_nearest(tex, in.uv - float2(texel.x * 0.5, 0));
        float4 r = tex_nearest(tex, in.uv + float2(texel.x * 0.5, 0));
        color.rgb = (color.rgb * 0.6 + (l.rgb + r.rgb) * 0.2) * darken;
        color.rgb *= 1.08;
    } else if (u.filter == 2) {
        // Grid: thin dark lines between emulated pixels, visible only when the
        // on-screen scale is ≥ 2px per texel.
        float2 scale = u.outputSize / u.textureSize;
        float2 f = fract(in.uv * u.textureSize);
        float2 px = f * scale;
        float lineW = 1.0;
        float g = 1.0;
        if (scale.x >= 2.0 && px.x < lineW) g *= 0.72;
        if (scale.y >= 2.0 && px.y < lineW) g *= 0.72;
        color.rgb *= g;
    }

    return float4(color.rgb, u.opacity);
}
