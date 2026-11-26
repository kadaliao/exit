// ============================================================================
//  Exit effect prelude
//  This file is prepended to every effect before it is compiled. It defines the
//  `Exit` uniforms, the entry points and a small helper library. Effects only
//  implement one function:
//
//      float4 effect(float2 p, constant Exit& u, texture2d<float> tex)
//
//  p    pixel position on the canvas (origin top-left, y grows downward)
//  u    uniforms (see struct Exit below)
//  tex  the window snapshot (premultiplied alpha). Use sampleWindow* helpers.
//
//  Return a PREMULTIPLIED color. Transparent black = nothing drawn.
//  rgb may exceed alpha for additive light (glows, sparks).
// ============================================================================
#include <metal_stdlib>
using namespace metal;

#define EVENT_CLOSE    0
#define EVENT_OPEN     1
#define EVENT_MINIMIZE 2
#define EVENT_QUIT     3

constant float PI  = 3.14159265358979;
constant float TAU = 6.28318530717959;

struct Exit {
    float4 win;          // window rect on the canvas in pixels: (x, y, width, height)
    float4 accent;       // accent color (rgb, 1)
    float2 size;         // canvas size in pixels
    float2 cursor;       // mouse position on the canvas in pixels, at trigger time
    float  progress;     // 0 -> 1 over the duration (linear; ease it yourself)
    float  time;         // seconds since start
    float  duration;     // total seconds
    float  seed;         // random 0..1, different on every play
    float  scale;        // pixels per point (2 on Retina). Multiply sizes by it.
    int    event;        // EVENT_CLOSE / EVENT_OPEN / EVENT_MINIMIZE / EVENT_QUIT
    int    hasSnapshot;  // 1 = real window image, 0 = stand-in card
    float  corner;       // window corner radius in pixels
    float  shadow;       // internal: 1 = fade out a stand-in for the real window's shadow
};

constexpr sampler exitSampler(coord::normalized, address::clamp_to_zero, filter::linear, mip_filter::linear);

// ---------------------------------------------------------------- window space

// Canvas pixel -> window uv (0..1 inside the window, origin top-left).
inline float2 toWindowUV(constant Exit& u, float2 p) { return (p - u.win.xy) / u.win.zw; }
// Window uv -> canvas pixel.
inline float2 fromWindowUV(constant Exit& u, float2 uv) { return u.win.xy + uv * u.win.zw; }
inline float2 windowCenter(constant Exit& u) { return u.win.xy + u.win.zw * 0.5; }
inline float2 windowSize(constant Exit& u) { return u.win.zw; }

// Snapshot color at window uv. Transparent outside 0..1.
inline float4 sampleWindowUV(texture2d<float> tex, float2 uv) { return tex.sample(exitSampler, uv); }
// Snapshot color at canvas pixel p. Transparent outside the window.
inline float4 sampleWindow(texture2d<float> tex, constant Exit& u, float2 p) {
    return tex.sample(exitSampler, toWindowUV(u, p));
}
// Full-resolution variants. Use these inside loops or branches that differ between
// neighbouring pixels (particles, shards): automatic mip selection breaks down there
// and smears the window's average color across the canvas.
inline float4 sampleWindowSharp(texture2d<float> tex, constant Exit& u, float2 p) {
    return tex.sample(exitSampler, toWindowUV(u, p), level(0.0));
}
inline float4 sampleWindowUVSharp(texture2d<float> tex, float2 uv) { return tex.sample(exitSampler, uv, level(0.0)); }
// Explicit mip level (0 = full resolution, higher = blurrier).
inline float4 sampleWindowLevel(texture2d<float> tex, constant Exit& u, float2 p, float lod) {
    return tex.sample(exitSampler, toWindowUV(u, p), level(lod));
}
// 1 in the middle of the canvas, falling to 0 within `width` pixels of its edge. Multiply
// particles by it so nothing gets cut off hard where the canvas ends.
inline float canvasEdgeFade(constant Exit& u, float2 p, float width) {
    float2 d = min(p, u.size - p);
    return smoothstep(0.0, width, min(d.x, d.y));
}

// --------------------------------------------------------------------- shapes

inline float sdCircle(float2 p, float r) { return length(p) - r; }
inline float sdBox(float2 p, float2 halfSize) {
    float2 d = abs(p) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
inline float sdRoundBox(float2 p, float2 halfSize, float r) { return sdBox(p, halfSize - r) - r; }
inline float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
// Signed distance to the (rounded) window outline in pixels. Negative inside.
inline float windowSDF(constant Exit& u, float2 p) {
    return sdRoundBox(p - windowCenter(u), u.win.zw * 0.5, u.corner);
}
inline float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

// ------------------------------------------------------------------ randomness

inline float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
inline float3 hash32(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}
// Value noise in -1..1-ish range mapped to 0..1.
inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}
inline float fbm(float2 p, int octaves) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) { v += a * noise(p); p = p * 2.03 + 17.17; a *= 0.5; }
    return v;
}

// ---------------------------------------------------------------------- easing

inline float easeInQuad(float t)     { return t * t; }
inline float easeOutQuad(float t)    { return 1.0 - (1.0 - t) * (1.0 - t); }
inline float easeInOutQuad(float t)  { return t < 0.5 ? 2.0 * t * t : 1.0 - pow(-2.0 * t + 2.0, 2.0) * 0.5; }
inline float easeInCubic(float t)    { return t * t * t; }
inline float easeOutCubic(float t)   { return 1.0 - pow(1.0 - t, 3.0); }
inline float easeInOutCubic(float t) { return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5; }
inline float easeInExpo(float t)     { return t <= 0.0 ? 0.0 : pow(2.0, 10.0 * t - 10.0); }
inline float easeOutExpo(float t)    { return t >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t); }
inline float easeInBack(float t)     { const float c = 1.70158; return (c + 1.0) * t * t * t - c * t * t; }
inline float easeOutBack(float t)    { const float c = 1.70158; float s = t - 1.0; return 1.0 + (c + 1.0) * s * s * s + c * s * s; }
inline float easeOutElastic(float t) {
    if (t <= 0.0) return 0.0; if (t >= 1.0) return 1.0;
    return pow(2.0, -10.0 * t) * sin((t * 10.0 - 0.75) * (TAU / 3.0)) + 1.0;
}
// Maps x from [a, b] to [0, 1], clamped.
inline float remap01(float x, float a, float b) { return clamp((x - a) / (b - a), 0.0, 1.0); }

// ----------------------------------------------------------------------- color

inline float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}
// Inigo Quilez cosine palette.
inline float3 palette(float t, float3 a, float3 b, float3 c, float3 d) { return a + b * cos(TAU * (c * t + d)); }
inline float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
// Premultiplied color from straight rgb + alpha.
inline float4 premul(float3 rgb, float a) { return float4(rgb * a, a); }
// Premultiplied "over": top drawn on bottom.
inline float4 over(float4 top, float4 bottom) { return top + bottom * (1.0 - top.a); }

// ------------------------------------------------------------------ entry glue

float4 effect(float2 p, constant Exit& u, texture2d<float> tex);

struct ExitVOut { float4 position [[position]]; };

vertex ExitVOut exit_vertex(uint vid [[vertex_id]]) {
    const float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    ExitVOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    return o;
}

fragment float4 exit_fragment(ExitVOut in [[stage_in]],
                              constant Exit& u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
    float2 p = in.position.xy;
    float4 c = effect(p, u, tex);
    if (u.shadow > 0.0) {
        // The real window had a shadow that vanished with it; let a stand-in dissolve quickly.
        float fade = 1.0 - smoothstep(0.0, 0.18, u.time);
        float inside = windowSDF(u, p);
        if (fade > 0.0 && inside > 0.0) {
            float d = max(sdRoundBox(p - windowCenter(u) - float2(0.0, 12.0 * u.scale), u.win.zw * 0.5, u.corner), 0.0);
            float a = 0.26 * exp(-d / (16.0 * u.scale)) + 0.16 * exp(-max(inside, 0.0) / (2.5 * u.scale));
            a *= fade * smoothstep(0.0, 1.5 * u.scale, inside);
            c = over(c, float4(0.0, 0.0, 0.0, a));
        }
    }
    return clamp(c, 0.0, 1.0);
}
