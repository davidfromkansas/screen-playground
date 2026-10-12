// Metal source compiled at runtime with MTLDevice.makeLibrary(source:), so the package
// builds with plain `swift build` and needs no offline Metal toolchain.
enum ShaderSource {
    static let code = #"""
#include <metal_stdlib>
using namespace metal;

// Must match `LayerUniforms` in Swift (128 bytes).
struct Uniforms {
    float4 rect;      // drawn quad in canvas pixels: x, y, w, h
    float4 uvRect;    // texture sub-rect: u0, v0, uw, vh
    float4 color;
    float4 color2;
    float4 params;
    float4 params2;
    float2 canvas;    // canvas size in pixels
    float2 pivot;     // rotation pivot, normalized within rect
    float radius;     // corner radius in pixels
    float opacity;
    float rotation;   // radians
    int mode;
};

enum Mode {
    MODE_SOLID = 0, MODE_TEXTURE = 1, MODE_SHADOW = 2, MODE_GRADIENT = 3, MODE_WALLPAPER = 4,
    MODE_RING = 5, MODE_DIM_OUTSIDE = 6, MODE_LOUPE = 7, MODE_COMPOSITE = 8, MODE_INSET = 9,
};

struct VOut {
    float4 position [[position]];
    float2 local;   // pixels within rect, origin top-left
    float2 uv;      // 0..1 within rect
    float2 canvasPx;
};

vertex VOut layer_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 local = corner * u.rect.zw;
    float2 pivot = u.pivot * u.rect.zw;
    float s = sin(u.rotation), c = cos(u.rotation);
    float2 d = local - pivot;
    float2 rotated = float2(d.x * c - d.y * s, d.x * s + d.y * c) + pivot;
    float2 px = u.rect.xy + rotated;
    VOut o;
    o.position = float4(px.x / u.canvas.x * 2.0 - 1.0, 1.0 - px.y / u.canvas.y * 2.0, 0, 1);
    o.local = local;
    o.uv = corner;
    o.canvasPx = px;
    return o;
}

// Signed distance to a rounded rectangle centered at the origin.
static float sdRoundRect(float2 p, float2 halfSize, float r) {
    r = min(r, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float roundedCoverage(float2 local, float2 size, float r) {
    float d = sdRoundRect(local - size * 0.5, size * 0.5, r);
    return clamp(0.5 - d, 0.0, 1.0);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float2 u2 = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u2.x), mix(c, d, u2.x), u2.y);
}

// Four-color mesh gradient with a soft domain warp, for procedural wallpapers.
static float3 wallpaper(float2 uv, float4 c0, float4 c1, float4 c2, float4 c3, float seed) {
    float2 p = uv;
    float n1 = noise(p * 2.3 + seed), n2 = noise(p * 2.7 - seed * 1.7);
    p += 0.22 * float2(n1 - 0.5, n2 - 0.5);
    float3 top = mix(c0.rgb, c1.rgb, smoothstep(0.0, 1.0, p.x));
    float3 bottom = mix(c2.rgb, c3.rgb, smoothstep(0.0, 1.0, p.x));
    float3 col = mix(top, bottom, smoothstep(0.0, 1.0, p.y));
    // Soft light blob for depth.
    float blob = exp(-8.0 * length(p - float2(0.3 + 0.4 * n1, 0.35)));
    return col + 0.12 * blob;
}

fragment float4 layer_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                               texture2d<float> tex [[texture(0)]],
                               constant float4* palette [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float2 size = u.rect.zw;
    float dither = (hash21(in.canvasPx) - 0.5) / 255.0;

    switch (u.mode) {
    case MODE_SOLID: {
        float a = roundedCoverage(in.local, size, u.radius) * u.color.a * u.opacity;
        return float4(u.color.rgb * a, a);
    }
    case MODE_TEXTURE: {
        float2 uv = in.uv;
        if (u.params.x > 0.5) uv.x = 1.0 - uv.x;  // mirror
        float2 tuv = u.uvRect.xy + uv * u.uvRect.zw;
        float4 c = tex.sample(smp, tuv);
        // params.y: 0 opaque video, 1 straight alpha (premultiply here), 2 already premultiplied.
        if (u.params.y > 1.5) {}
        else if (u.params.y > 0.5) c.rgb *= c.a;
        else c.a = 1.0;
        float a = roundedCoverage(in.local, size, u.radius) * u.opacity;
        return c * a;
    }
    case MODE_SHADOW: {
        // params: inner rect (x,y,w,h) in canvas px; params2.x: blur radius.
        float2 center = u.params.xy + u.params.zw * 0.5;
        float d = sdRoundRect(in.canvasPx - center, u.params.zw * 0.5, u.radius);
        float blur = max(u.params2.x, 1.0);
        float a = (1.0 - smoothstep(-blur, blur, d)) * u.color.a * u.opacity;
        // Gentler falloff curve.
        a = a * a * (3.0 - 2.0 * a);
        return float4(0, 0, 0, a);
    }
    case MODE_GRADIENT: {
        float2 p = in.uv;
        float2 dir = u.params.zw - u.params.xy;
        float t = clamp(dot(p - u.params.xy, dir) / max(dot(dir, dir), 1e-5), 0.0, 1.0);
        float3 col = mix(u.color.rgb, u.color2.rgb, t) + dither;
        return float4(col, 1.0);
    }
    case MODE_WALLPAPER: {
        float3 col = wallpaper(in.uv, palette[0], palette[1], palette[2], palette[3], u.params2.x) + dither;
        return float4(col, 1.0);
    }
    case MODE_RING: {
        // params.x: progress 0..1, params.y: kind (1 circle, 2 ripple, 3 shockwave)
        float2 p = in.local - size * 0.5;
        float r = length(p);
        float maxR = size.x * 0.5;
        float prog = clamp(u.params.x, 0.0, 1.0);
        float ease = 1.0 - pow(1.0 - prog, 3.0);
        float a = 0.0;
        if (u.params.y < 1.5) {          // circle: filled, shrinking fade
            float rad = maxR * (0.35 + 0.35 * ease);
            a = (1.0 - smoothstep(rad - 1.5, rad + 1.5, r)) * (1.0 - prog) * 0.45;
        } else if (u.params.y < 2.5) {   // ripple: expanding ring
            float rad = maxR * ease;
            float w = maxR * 0.08 + 2.0;
            a = (1.0 - smoothstep(0.0, w, abs(r - rad))) * (1.0 - prog);
        } else {                         // shockwave: thick ring + faint fill
            float rad = maxR * ease;
            float w = maxR * 0.18;
            a = (1.0 - smoothstep(0.0, w, abs(r - rad))) * (1.0 - prog) * 0.8;
            a += (1.0 - smoothstep(rad - 2.0, rad, r)) * (1.0 - prog) * 0.12;
        }
        a *= u.color.a * u.opacity;
        return float4(u.color.rgb * a, a);
    }
    case MODE_DIM_OUTSIDE: {
        // params: hole rect in canvas px.
        float2 center = u.params.xy + u.params.zw * 0.5;
        float d = sdRoundRect(in.canvasPx - center, u.params.zw * 0.5, u.radius);
        float a = smoothstep(-1.0, 1.0, d) * u.opacity;
        return float4(0, 0, 0, a);
    }
    case MODE_LOUPE: {
        // Circle that shows the texture magnified. params.xy: center in texture uv; params.z: magnification;
        // params.w: texture aspect (w/h) relative to the loupe's pixel size.
        float2 p = in.uv - 0.5;
        float r = length(p) * 2.0;
        float inside = 1.0 - smoothstep(0.985, 1.0, r);
        float2 offset = p * u.params2.xy / u.params.z;
        // Slight barrel refraction near the rim.
        offset *= 1.0 - 0.12 * pow(r, 4.0);
        float4 c = tex.sample(smp, u.params.xy + offset);
        c.a = 1.0;
        float rim = smoothstep(0.90, 0.985, r) * (1.0 - smoothstep(0.985, 1.0, r));
        float3 col = mix(c.rgb, float3(1.0), rim * 0.55);
        float a = inside * u.opacity;
        return float4(col * a, a);
    }
    case MODE_COMPOSITE: {
        float4 c = tex.sample(smp, in.uv);
        return c * u.opacity;
    }
    case MODE_INSET: {
        // Ring between the outer rounded rect and one inset by params.x pixels.
        float outer = roundedCoverage(in.local, size, u.radius);
        float w = u.params.x;
        float inner = roundedCoverage(in.local - w, size - 2.0 * w, max(u.radius - w, 0.0));
        float a = clamp(outer - inner, 0.0, 1.0) * u.color.a * u.opacity;
        return float4(u.color.rgb * a, a);
    }
    }
    return float4(1, 0, 1, 1);
}
"""#
}
