// @name Pixel Dissolve
// @name.zh 像素消散
// @author Exit
// @description The window crumbles into square pixels that lift off in a wave and float away.
// @description.zh 窗口碎成方块像素，像波浪一样一块块飘起、缩小、消散。
// @duration 0.95
// @padding 230
// @events close, quit, minimize

// Every block moves along the same direction D (only its speed differs), so the block
// covering a pixel can be found by walking the block grid backwards along -D (DDA).

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    if (t <= 0.0) return sampleWindow(tex, u, p);
    if (t >= 1.0) return float4(0.0);

    float S = u.scale;
    float B = 11.0 * S;                                   // block size in pixels
    float2 grid = ceil(u.win.zw / B);

    // Drift: upward, tilted a little by the seed.
    float ang = (u.seed - 0.5) * 0.7;
    float2 D = float2(sin(ang), -cos(ang));
    if (abs(D.x) < 0.02) D.x = 0.02;
    D = normalize(D);
    float L = min(150.0 + 0.25 * u.win.z / S, 380.0) * S; // travel distance in pixels

    // Nothing can reach below the window or far above it.
    if (p.y > u.win.y + u.win.w + B) return float4(0.0);
    if (p.y < u.win.y - L - B) return float4(0.0);

    // Wave direction for the stagger.
    float pick = fract(u.seed * 7.31);
    float2 sweepDir = pick < 0.34 ? float2(0.0, 1.0)
                    : (pick < 0.67 ? normalize(float2(0.7, 1.0)) : normalize(float2(-0.7, 1.0)));
    float sweepNorm = 0.5 * (abs(sweepDir.x) + abs(sweepDir.y));
    float seedOffset = floor(u.seed * 97.0);
    float3 glintCol = mix(float3(1.0), u.accent.rgb, 0.35);

    // DDA through the block grid, starting at p and walking along -D.
    float2 ro = (p - u.win.xy) / B;
    float2 rd = -D;
    float2 cell = floor(ro);
    float2 stp = sign(rd);
    float2 tDelta = abs(1.0 / rd);
    float2 tMax = (select(cell, cell + 1.0, stp > 0.0) - ro) / rd;
    float maxT = L / B + 1.5;

    float4 result = float4(0.0);
    for (int i = 0; i < 96; i++) {
        if (all(cell >= 0.0) && all(cell < grid)) {
            float2 cuv = (cell + 0.5) / grid;
            float h = hash21(cell + seedOffset);
            float sweep = dot(cuv - 0.5, sweepDir) / sweepNorm * 0.5 + 0.5;   // 0..1
            float delay = 0.02 + sweep * 0.50 + h * 0.13;
            float lt = clamp((t - delay) / 0.33, 0.0, 1.0);
            float m = L * (0.2 * lt + 0.8 * lt * lt) * (0.85 + 0.3 * hash11(h * 91.7));
            float shrink = 1.0 - 0.62 * lt;
            float2 cc = u.win.xy + (cell + 0.5) * B;
            float2 d = p - (cc + D * m);
            float halfB = 0.5 * B * shrink;
            float md = max(abs(d.x), abs(d.y));
            if (md <= halfB + 0.75) {
                float cov = lt > 0.0 ? clamp(halfB - md + 0.75, 0.0, 1.0) : (md <= halfB ? 1.0 : 0.0);
                // Explicit LOD: implicit derivatives are undefined inside this divergent branch.
                float4 col = tex.sample(exitSampler, toWindowUV(u, lt > 0.0 ? cc + d / shrink : p), level(0.0));
                // A quick glint as the block detaches, then fade.
                float glint = lt * (1.0 - lt) * 4.0;
                col.rgb += glintCol * col.a * 0.28 * glint * glint;
                col *= (1.0 - smoothstep(0.35, 1.0, lt)) * cov;
                result = over(col, result);
            }
        }
        float tNext = min(tMax.x, tMax.y);
        if (tNext > maxT) break;
        if (tMax.x < tMax.y) { tMax.x += tDelta.x; cell.x += stp.x; }
        else                 { tMax.y += tDelta.y; cell.y += stp.y; }
    }
    return result;
}
