// @name Sticker Peel
// @name.zh 贴纸撕下
// @author Exit
// @description Peels up from a corner like a die-cut sticker, then the whole sticker lifts away.
// @description.zh 像一张贴纸那样从一角卷起，随后整张被揭起拿走。
// @duration 1.05
// @padding 220
// @events close, quit, minimize

// Exact (mip level 0) sample: the peel mapping is discontinuous, so derivative-based
// mip selection would bleed coarse levels along the fold lines.
inline float4 sticker_sample(texture2d<float> tex, constant Exit& u, float2 p) {
    return tex.sample(exitSampler, toWindowUV(u, p), level(0.0));
}

// Back side of the sticker: silvery white with a soft sheen and faint print-through.
float3 sticker_back(float3 print, float light, float spec) {
    float3 base = float3(0.93, 0.94, 0.965);
    float3 c = base * (0.62 + 0.38 * light) + float3(spec);
    return mix(c, print, 0.05);
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    if (t <= 0.0) return sampleWindow(tex, u, p);

    float2 W = windowSize(u);
    // Peel from one of the four corners (bottom corners are more likely: it reads better).
    float pick = fract(u.seed * 7.31);
    int corner = pick < 0.4 ? 2 : pick < 0.8 ? 3 : pick < 0.9 ? 1 : 0;   // 0 TL, 1 TR, 2 BR, 3 BL
    float2 sgn = corner == 0 ? float2(1, 1) : corner == 1 ? float2(-1, 1) : corner == 2 ? float2(-1, -1) : float2(1, -1);
    float2 cornerPos = u.win.xy + W * (0.5 - 0.5 * sgn);
    float2 dir = normalize(sgn * float2(1.0, 0.8));
    float L = dot(W, abs(dir));
    float sizeK = clamp(min(W.x, W.y) / (420.0 * s), 0.6, 1.6);

    // Phase A: peel the corner back. Phase B: the whole sticker lifts off toward the viewer.
    float peel = remap01(t, 0.0, 0.70);
    float lift = easeInCubic(remap01(t, 0.50, 1.0));
    float R = (12.0 + 26.0 * peel) * s * sizeK;                     // curl radius grows as it peels
    float c = (0.50 * L + PI * R) * (0.55 * peel + 0.45 * easeInOutQuad(peel));
    const float k = 0.52;                                            // flap foreshortening (lifted toward the viewer)
    float shadowAmt = remap01(c, 0.0, 3.0 * R);

    // Undo the lift-off transform to find the point in sticker space.
    float2 pivot = windowCenter(u);
    float2 fly = (dir * 0.16 * L + float2(0.0, -50.0 * s)) * lift;
    float sc = 1.0 + 0.16 * lift;
    float ang = (corner == 2 || corner == 0 ? 1.0 : -1.0) * 0.16 * lift;
    float2 ps = pivot + rot(-ang) * (p - pivot - fly) / sc;

    float sp = dot(ps - cornerPos, dir);
    #define PAPER(s0) sticker_sample(tex, u, ps + ((s0) - sp) * dir)

    float4 outc = float4(0.0);
    bool done = false;

    // 1) The lifted flap (back side up), foreshortened.
    if (sp >= c) {
        float s0 = c - PI * R - (sp - c) / k;
        float4 w = PAPER(s0);
        if (w.a > 0.002) {
            float x = (sp - c) / max(k * (c - PI * R), 1.0);
            float spec = 0.12 * exp(-(sp - c) / (2.0 * R)) + 0.10 * exp(-pow((x - 0.35) / 0.18, 2.0));
            float3 col = sticker_back(w.rgb / max(w.a, 1e-3), 0.88 + 0.12 * x, spec);
            outc = premul(col, w.a);
            done = w.a > 0.995;
        }
    }

    // 2) The curl.
    if (!done && sp >= c - R && sp < c) {
        float x = clamp((c - sp) / R, 0.0, 1.0);
        float phiU = PI - asin(x);                                   // upper half: back side
        float4 w = PAPER(c - R * phiU);
        if (w.a > 0.002) {
            float nz = -cos(phiU);
            float spec = 0.55 * exp(-pow((phiU - 0.74 * PI) / 0.16, 2.0));
            outc = over(outc, premul(sticker_back(w.rgb / max(w.a, 1e-3), nz, spec), w.a));
            done = outc.a > 0.995;
        }
        if (!done) {
            float phiL = asin(x);                                    // lower half: printed side, in shade
            float4 f = PAPER(c - R * phiL);
            if (f.a > 0.002) {
                outc = over(outc, float4(f.rgb * (0.45 + 0.4 * cos(phiL)), f.a));
                done = outc.a > 0.995;
            }
        }
    }

    // 3) The part still stuck down, shaded by the flap hanging over it.
    if (!done && sp >= c) {
        float4 f = sticker_sample(tex, u, ps);
        if (f.a > 0.0) {
            float shade = 1.0 - 0.30 * shadowAmt * exp(-(sp - c) / (1.6 * R))
                              - 0.10 * shadowAmt * exp(-(sp - c) / (6.0 * R));
            outc = over(outc, float4(f.rgb * shade, f.a));
            done = outc.a > 0.995;
        }
    }

    // 4) Soft shadow on the desktop: under the curl, then under the whole lifted sticker.
    if (!done) {
        float2 onFold = ps + (c - sp) * dir;
        float inCol = 1.0 - smoothstep(-2.0 * s, 10.0 * s, windowSDF(u, onFold));
        float curlSh = 0.24 * shadowAmt * exp(-abs(sp - (c - 0.4 * R)) / (1.6 * R)) * inCol;
        float2 shp = pivot + (p - pivot - fly * 0.6 - float2(0.0, 26.0 * s) * lift) / (1.0 + 0.06 * lift);
        float blur = (14.0 + 50.0 * lift) * s;
        float liftSh = 0.20 * sin(PI * min(lift * 1.2, 1.0)) * (1.0 - smoothstep(-blur, blur, windowSDF(u, shp)));
        float sh = max(curlSh * (1.0 - lift), liftSh);
        outc = over(outc, float4(0.0, 0.0, 0.0, sh));
    }
    #undef PAPER

    float fade = 1.0 - easeInOutQuad(remap01(t, 0.62, 1.0));
    float border = min(min(p.x, p.y), min(u.size.x - p.x, u.size.y - p.y));
    float edgeFade = mix(1.0, smoothstep(0.0, 60.0 * s, border), shadowAmt);
    return outc * fade * edgeFade;
}
