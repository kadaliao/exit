// @name Confetti
// @name.zh 彩纸礼花
// @author Exit
// @description The window pops and bursts into a shower of fluttering paper confetti.
// @description.zh 窗口“啵”地一下炸成漫天飘落的彩色纸屑。
// @duration 1.4
// @padding 280
// @events close, quit, minimize

constant float3 confetti_colors[8] = {
    float3(1.00, 0.30, 0.38), float3(1.00, 0.78, 0.18), float3(0.28, 0.84, 0.46),
    float3(0.24, 0.58, 1.00), float3(0.70, 0.40, 1.00), float3(1.00, 0.50, 0.78),
    float3(0.18, 0.86, 0.92), float3(1.00, 0.58, 0.20)
};

// One confetti piece at offset d from its center. Returns premultiplied color.
float4 confetti_piece(float2 d, float Tp, float3 r, int ci, float s) {
    float size = mix(6.0, 11.5, r.x) * s;
    if (dot(d, d) > size * size * 1.3) return float4(0.0);
    d = rot(-(r.y * TAU + (r.z - 0.5) * 24.0 * Tp)) * d;
    float flip = cos(Tp * mix(7.0, 16.0, r.z) + r.x * TAU);
    float cov;
    if (r.y < 0.2) {
        float2 e = d / float2(max(abs(flip), 0.15), 1.0);           // round sequin
        cov = 1.0 - smoothstep(-0.6 * s, 0.6 * s, length(e) - size * 0.55);
    } else {
        float2 hs = float2(size * 0.95, size * 0.42 * max(abs(flip), 0.07));
        cov = 1.0 - smoothstep(-0.6 * s, 0.6 * s, sdBox(d, hs));
    }
    if (cov <= 0.0) return float4(0.0);
    float3 col = confetti_colors[ci & 7];
    col *= flip > 0.0 ? 0.78 + 0.22 * flip : 0.58 + 0.22 * -flip;   // two-tone paper
    col += pow(abs(flip), 16.0) * 0.35;                              // sheen when facing us
    return premul(col, cov);
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    if (t <= 0.0) return sampleWindow(tex, u, p);

    float2 W = windowSize(u);
    float2 ctr = windowCenter(u);

    // Window: a tiny inflate, then pops away with a white flash.
    float inflate = 0.04 * sin(PI * remap01(t, 0.0, 0.12));
    float pop = easeInCubic(remap01(t, 0.08, 0.17));
    float sc = 1.0 + inflate - 0.15 * pop;
    float4 win = sampleWindow(tex, u, ctr + (p - ctr) / sc);
    win.rgb = mix(win.rgb, float3(win.a), 0.75 * remap01(t, 0.06, 0.15));
    win *= 1.0 - pop;

    float4 acc = float4(0.0);

    // Soft burst halo.
    float2 q = (p - ctr) / (W * 0.5);
    float ringR = mix(0.5, 1.45, easeOutCubic(remap01(t, 0.10, 0.40)));
    float ringA = remap01(t, 0.10, 0.13) * (1.0 - remap01(t, 0.13, 0.40));
    float ring = exp(-pow((length(q) - ringR) / 0.03, 2.0)) * ringA;
    acc.rgb += float3(1.0, 0.90, 0.70) * ring * 0.30;

    const float burst = 0.12;
    if (t > burst) {
        float Tp = (t - burst) * u.duration;
        const float drag = 3.0;
        const float g = 1300.0;
        float ed = (1.0 - exp(-drag * Tp)) / drag;
        float fall = (g * s / drag) * (Tp - ed);
        float spread = (ed * drag) * 85.0 * s;                         // cluster members drift apart
        float flutterAmp = remap01(Tp, 0.15, 0.6) * 16.0 * s;
        float border = min(min(p.x, p.y), min(u.size.x - p.x, u.size.y - p.y));
        float edgeFade = smoothstep(0.0, 50.0 * s, border);
        float clusterR = spread * 1.5 + flutterAmp + 14.0 * s;

        // 56 clusters x 3 pieces.
        for (int i = 0; i < 56; i++) {
            float3 r = hash32(float2(float(i) * 1.618 + 0.5, u.seed * 91.3 + 3.0));
            float2 start = u.win.xy + W * (0.06 + 0.88 * r.xy);
            float2 out = (start - ctr) / max(W.x, W.y);
            float2 dir = out * 1.6 + (r.zx - 0.5) * 0.8 + float2(0.0, -0.55);
            float2 pos = start + dir * (mix(700.0, 1500.0, r.z) * s * ed);
            pos.y += fall;
            float2 d0 = p - pos;
            if (dot(d0, d0) > clusterR * clusterR) continue;

            for (int j = 0; j < 3; j++) {
                float3 rj = fract(r * float3(13.17, 7.31, 5.77) * float(j + 1) + r.zxy + float(j) * 0.37);
                float2 off = (rj.xy - 0.5) * 2.0 * spread;
                off.x += sin(Tp * mix(5.0, 10.0, rj.z) + rj.x * TAU) * flutterAmp;
                float4 c = confetti_piece(d0 - off, Tp, rj, i * 3 + j, s);
                if (c.a <= 0.0) continue;
                float life = 1.0 - remap01(t, 0.55 + 0.38 * rj.y, 0.98);
                acc = over(c * life * edgeFade, acc);
            }
        }
    }

    float4 res = over(acc, win);
    return res * (1.0 - remap01(t, 0.97, 1.0));
}
