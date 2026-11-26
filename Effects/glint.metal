// @name Glint
// @name.zh 流光
// @author Exit
// @description A sheet of light sweeps across the new window as its edge glows in your accent color.
// @description.zh 一道光扫过新窗口，边缘以系统强调色微微亮起。
// @duration 0.9
// @padding 70
// @events open

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    float2 W = windowSize(u);
    float sd = windowSDF(u, p);
    float4 w = sampleWindow(tex, u, p);
    float onWin = max(w.a, 1.0 - smoothstep(-1.0 * s, 0.5 * s, sd));

    // Diagonal sweep.
    float2 n = normalize(float2(1.0, 0.6));
    float proj = dot(p - u.win.xy, n);
    float L = dot(W, n);
    float bw = max(0.10 * L, 50.0 * s);
    float pos = mix(-0.3 * L, 1.3 * L, easeInOutCubic(remap01(t, 0.04, 0.78)));
    float x = (proj - pos) / bw;
    float band = exp(-x * x) * 0.20 + exp(-x * x * 40.0) * 0.30;
    float sweepAmt = sin(PI * remap01(t, 0.04, 0.78));
    float sweep = band * sweepAmt * onWin;

    // Accent glow around the edge: rises quickly, fades slowly.
    float pulse = smoothstep(0.0, 0.16, t) * (1.0 - smoothstep(0.30, 1.0, t));
    float outside = sd > 0.0 ? exp(-sd / (14.0 * s)) * 0.55 + exp(-sd / (40.0 * s)) * 0.18 : 0.0;
    float rim = exp(-abs(sd) / (1.1 * s)) * 0.9;
    float inner = sd < 0.0 ? exp(sd / (6.0 * s)) * 0.18 : 0.0;
    float glow = (outside + rim + inner) * pulse;

    float3 acc = clamp(u.accent.rgb * 1.15 + 0.1, 0.0, 1.0);
    float3 light = float3(1.0, 0.98, 0.94) * sweep + acc * glow;
    float alpha = 0.10 * sweep + 0.22 * outside * pulse;
    return float4(light, alpha);
}
