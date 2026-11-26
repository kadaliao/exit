// @name Old TV
// @name.zh 老电视
// @author Exit
// @description CRT power-off: collapses to a glowing line, then a dot.
// @description.zh 显像管关机：压成一道亮线，再缩成一个光点。
// @duration 0.62
// @padding 120
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float2 c = windowCenter(u);
    float2 hs = windowSize(u) * 0.5;
    float px = u.scale;

    // Phase 1: squash vertically. Phase 2: squash horizontally. Phase 3: dot fades.
    float sy = 1.0 - easeInCubic(remap01(t, 0.0, 0.40));
    float sx = 1.0 - easeInQuad(remap01(t, 0.40, 0.74));
    float lineH = 1.2 * px;
    float halfH = max(hs.y * sy, lineH);
    float halfW = max(hs.x * sx, 1.5 * px) * (1.0 + 0.06 * remap01(t, 0.15, 0.40));

    // Sample the squashed window.
    float2 q = (p - c) / float2(halfW, halfH);          // -1..1 inside the squashed rect
    float4 col = sampleWindow(tex, u, c + q * hs);
    float inside = step(abs(q.x), 1.0) * step(abs(q.y), 1.0);
    col *= inside;

    // Brighten toward white as it collapses, plus scanlines.
    float flash = remap01(t, 0.12, 0.42);
    col.rgb = mix(col.rgb, float3(col.a), flash);
    float scan = 0.9 + 0.1 * sin(p.y / px * 2.2);
    col.rgb *= mix(1.0, scan, remap01(t, 0.0, 0.15) * (1.0 - flash));
    // Slight chroma shift while squashing.
    float shift = 3.0 * px * remap01(t, 0.05, 0.35) * (1.0 - flash);
    float r = sampleWindow(tex, u, c + (q + float2(shift / halfW, 0)) * hs).r * inside;
    col.r = mix(col.r, max(col.r, r), 0.6);

    // Glow around the collapsing shape.
    float d = max(sdBox(p - c, float2(halfW, halfH)), 0.0);
    float glowAmt = remap01(t, 0.25, 0.45) * (1.0 - remap01(t, 0.82, 1.0));
    float glow = exp(-d / (10.0 * px)) * 0.55 + exp(-d / (40.0 * px)) * 0.25;
    float3 tint = mix(float3(0.75, 0.9, 1.0), float3(1.0), 0.5);
    float4 g = float4(tint * glow * glowAmt, glow * glowAmt * 0.6);

    // Final dot fade.
    float fade = 1.0 - remap01(t, 0.80, 1.0);
    return (over(col, g)) * fade;
}
