// @name Vacuum
// @name.zh 吸入光标
// @author Exit
// @description Sucked into the spot you clicked, swirling down to a point.
// @description.zh 被吸进你点击的位置，打着旋缩成一个点。
// @duration 0.75
// @padding 90
// @events close, quit, minimize

// Final radius of a point that started at radius r0 (near points collapse first).
inline float vacuum_r(float r0, float t, float Rmax) {
    float lt = clamp((t - 0.5 * (r0 / Rmax)) / 0.5, 0.0, 1.0);
    float E = easeInCubic(lt) * 0.85 + easeInQuad(lt) * 0.15;
    return r0 * (1.0 - E);
}

inline float vacuum_E(float r0, float t, float Rmax) {
    float lt = clamp((t - 0.5 * (r0 / Rmax)) / 0.5, 0.0, 1.0);
    return easeInCubic(lt) * 0.85 + easeInQuad(lt) * 0.15;
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    if (t <= 0.0) return sampleWindow(tex, u, p);

    float2 W = windowSize(u);
    float2 C = clamp(u.cursor, u.win.xy, u.win.xy + W);
    float2 far = max(abs(u.win.xy - C), abs(u.win.xy + W - C));
    float Rmax = length(far) + 1.0;

    float2 d = p - C;
    float r = length(d);
    float4 col = float4(0.0);

    if (vacuum_r(Rmax, t, Rmax) >= r) {
        // Invert r = f(r0) by bisection (f is monotonic).
        float lo = r, hi = Rmax;
        for (int i = 0; i < 16; i++) {
            float mid = 0.5 * (lo + hi);
            if (vacuum_r(mid, t, Rmax) < r) lo = mid; else hi = mid;
        }
        float r0 = 0.5 * (lo + hi);
        float E = vacuum_E(r0, t, Rmax);
        float swirl = (fract(u.seed * 3.7) > 0.5 ? 1.0 : -1.0) * 1.6 * E * E;
        float a = atan2(d.y, d.x) - swirl;
        float2 src = C + r0 * float2(cos(a), sin(a));
        // Explicit LOD: this branch is non-uniform, so implicit derivatives are unreliable.
        float lod = clamp(log2(1.0 / max(1.0 - E, 0.02)) * 0.7, 0.0, 5.0);
        col = tex.sample(exitSampler, toWindowUV(u, src), level(lod));
        // Compressed parts get dimmer and pick up a streak of light.
        col.rgb *= 1.0 - 0.35 * E;
        col.rgb += float3(0.9, 0.95, 1.0) * col.a * 0.35 * E * E;
    }

    // Small flash where it disappears.
    float flash = sin(PI * remap01(t, 0.72, 1.0));
    float glow = exp(-r / (10.0 * s)) * 0.9 + exp(-r / (34.0 * s)) * 0.3;
    float3 tint = mix(float3(1.0), u.accent.rgb, 0.45);
    float4 g = float4(tint * glow * flash, glow * flash * 0.25);

    return over(g, col) * (1.0 - remap01(t, 0.94, 1.0));
}
