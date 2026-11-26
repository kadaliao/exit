// @name Glitch
// @name.zh 故障
// @author Exit
// @description Digital breakdown: RGB split, torn slices and noise bursts escalate until the signal drops.
// @description.zh 数字信号崩坏：RGB 分离、画面撕裂、噪点爆发越来越强，最后信号中断。
// @duration 0.8
// @padding 160
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    if (t <= 0.0) return sampleWindow(tex, u, p);
    if (t >= 1.0) return float4(0.0);

    float S = u.scale;
    float tick = floor(u.time * 24.0) + floor(u.seed * 1000.0);    // stepped like a bad signal
    float I = pow(remap01(t, 0.0, 0.68), 1.25);                       // escalating intensity
    float burst = step(0.55, hash11(tick * 1.7 + 0.3));
    float amp = I * (0.35 + 0.65 * burst);

    // Collapse to a bright line, then blink out.
    float squash = easeInCubic(remap01(t, 0.68, 0.88));
    float2 c = windowCenter(u);
    float sy = mix(1.0, 0.012, squash);
    float sx = 1.0 + 0.18 * squash;
    float2 q = c + (p - c) / float2(sx, sy);

    // Horizontal slice tearing.
    float sliceH = mix(5.0, 46.0, hash11(tick + 2.0)) * S;
    float sliceId = floor((q.y - u.win.y) / sliceH + hash11(tick + 3.0) * 7.0);
    float shiftOn = step(1.0 - amp * 0.75, hash21(float2(sliceId * 1.3, tick + 9.0)));
    float dx = (hash21(float2(sliceId, tick)) - 0.5) * amp * 0.28 * u.win.z * shiftOn;
    // Scanline jitter.
    dx += (hash21(float2(floor(q.y / S), tick)) - 0.5) * 3.0 * S * amp;

    // Block displacement.
    float2 bsize = float2(90.0, 22.0) * S * (0.5 + hash11(tick + 5.0));
    float2 bid = floor((q - u.win.xy) / bsize);
    float bh = hash21(bid + tick * 0.37);
    float2 boff = (hash22(bid + tick) - 0.5) * float2(70.0, 14.0) * S * step(1.0 - amp * 0.35, bh);

    float2 sp = q + float2(dx, 0.0) + boff;
    float split = (5.0 + 20.0 * burst) * S * amp + 4.0 * S * squash;
    // Explicit LOD: torn slices make screen-space derivatives jump, which would blur seams.
    float4 cr = tex.sample(exitSampler, toWindowUV(u, sp + float2(split, 0.0)), level(0.0));
    float4 cg = tex.sample(exitSampler, toWindowUV(u, sp), level(0.0));
    float4 cb = tex.sample(exitSampler, toWindowUV(u, sp - float2(split, 0.0)), level(0.0));
    float4 col = float4(cr.r, cg.g, cb.b, max(cg.a, max(cr.a, cb.a)));

    // Inverted blocks and tinted slices.
    float inv = step(1.0 - amp * 0.12, hash21(bid * 1.7 + tick * 0.21));
    col.rgb = mix(col.rgb, col.a - col.rgb, inv);
    float tintOn = step(1.0 - amp * 0.2, hash21(float2(sliceId * 0.7, tick + 17.0)));
    float3 tint = hash11(sliceId + tick) > 0.5 ? float3(0.2, 1.0, 1.0) : float3(1.0, 0.2, 0.9);
    col.rgb = mix(col.rgb, col.rgb * tint, tintOn * 0.8);

    // Static noise bursts.
    float2 nid = floor((q - u.win.xy) / (float2(60.0, 10.0) * S));
    float noiseOn = step(1.0 - amp * 0.18 * burst, hash21(nid + tick * 1.31));
    float n = hash21(floor(p / S) + tick * 3.7);
    col = mix(col, float4(float3(n), 1.0) * col.a, noiseOn * 0.85);

    // Brighten while collapsing into the line.
    col.rgb = mix(col.rgb, float3(col.a), squash * 0.85);

    // Blink out at the end.
    float blinkOn = step(0.45, hash11(tick * 3.1 + 0.7));
    float fade = 1.0 - remap01(t, 0.88, 1.0);
    float vis = t < 0.88 ? 1.0 : blinkOn * fade;
    return col * vis;
}
