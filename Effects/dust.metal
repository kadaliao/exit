// @name Dust
// @name.zh 灰飞烟灭
// @author Exit
// @description A sweep turns the window into fine dust that drifts up and away on the wind.
// @description.zh 窗口从一侧开始化成细小的灰烬，被风吹散、飘向远处。
// @duration 1.35
// @padding 260
// @events close, quit, minimize

// Particles belong to one of DUST_K "wind classes". Inside a class every particle shares a
// direction and speed, and release time varies smoothly with position, so the source of a
// pixel can be found per class with a short fixed-point iteration.

constant int DUST_K = 6;

// Explicit LOD: samples happen in divergent branches where implicit derivatives are undefined.
inline float4 dust_sample(texture2d<float> tex, constant Exit& u, float2 pos) {
    return tex.sample(exitSampler, toWindowUV(u, pos), level(0.0));
}

float dust_release(float2 s, constant Exit& u, float ltr, float S) {
    float2 uv = (s - u.win.xy) / u.win.zw;
    float x = ltr > 0.0 ? uv.x : 1.0 - uv.x;
    float n = fbm(s / (90.0 * S) + u.seed * 17.0, 2);
    return 0.04 + 0.40 * clamp(x, -0.2, 1.2) + 0.12 * n + 0.03 * clamp(uv.y, 0.0, 1.0);
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    if (t <= 0.0) return sampleWindow(tex, u, p);
    if (t >= 1.0) return float4(0.0);

    float S = u.scale;
    float P = 2.5 * S;                                       // particle size
    float ltr = fract(u.seed * 3.7) > 0.7 ? -1.0 : 1.0;      // sweep direction
    float2 baseDir = normalize(float2(ltr, -0.6));
    float L = min(170.0 + 0.2 * u.win.z / S, 320.0) * S;     // travel
    const float life = 0.34;

    // Dust only travels upward and with the wind.
    float margin = 24.0 * S;
    if (p.y > u.win.y + u.win.w + margin) return float4(0.0);
    if (ltr > 0.0 && p.x < u.win.x - margin) return float4(0.0);
    if (ltr < 0.0 && p.x > u.win.x + u.win.z + margin) return float4(0.0);

    // Smooth turbulence, only where the window has already let go.
    float relP = clamp((t - max(dust_release(p, u, ltr, S), 0.02)) * 4.0, 0.0, 1.0);
    if (relP > 0.0) {
        float2 tp = p / (38.0 * S);
        float2 w = float2(noise(tp + float2(0.0, u.time * 1.3)), noise(tp + float2(5.2, 1.3 - u.time * 1.1))) - 0.5;
        p += w * 32.0 * S * relP;
    }

    float seedOff = floor(u.seed * 31.0);
    float4 base = float4(0.0);
    float4 dust = float4(0.0);
    for (int k = 0; k < DUST_K; k++) {
        float fk = float(k);
        float ang = (hash11(fk * 3.1 + 1.7 + seedOff) - 0.5) * 0.9;
        float spd = 0.55 + 0.9 * hash11(fk * 7.3 + 4.1 + seedOff);
        float2 D = rot(ang * ltr) * baseDir;
        float delay = fk / float(DUST_K) * 0.08;

        // Solve s = p - D * travel(release(s)).
        float2 s = p;
        float lt = 0.0;
        for (int it = 0; it < 4; it++) {
            lt = clamp((t - dust_release(s, u, ltr, S) - delay) / life, 0.0, 1.0);
            s = p - D * (L * spd * (0.25 * lt + 0.75 * lt * lt));
        }

        float2 cf = (s - u.win.xy) / P;
        float2 cell = floor(cf);
        int cls = int(hash21(cell + seedOff) * float(DUST_K));
        if (cls != k) continue;

        if (lt <= 0.0) {                                  // still part of the window
            base = dust_sample(tex, u, s);
            continue;
        }
        float h2 = hash21(cell * 1.7 + 3.3);
        float ltp = clamp(lt * (0.75 + 0.55 * h2), 0.0, 1.0);
        float shrink = 1.0 - 0.55 * ltp;
        float2 local = fract(cf) - 0.5;
        if (max(abs(local.x), abs(local.y)) > 0.5 * shrink) continue;
        float4 col = dust_sample(tex, u, u.win.xy + (cell + 0.5 + local / shrink) * P);
        // Embers of color cool into grey-brown ash.
        float lum = luminance(col.rgb / max(col.a, 1e-3));
        float3 ash = float3(0.36, 0.32, 0.29) * (0.55 + 0.7 * lum) * col.a;
        col.rgb = mix(col.rgb, ash, smoothstep(0.0, 0.7, ltp) * 0.85);
        col *= 1.0 - smoothstep(0.25, 1.0, ltp);
        dust = over(col, dust);
    }
    return over(dust, base);
}
