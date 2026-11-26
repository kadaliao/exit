// @name Melt
// @name.zh 融化
// @author Exit
// @description Melts like warm wax: the bottom edge sags into glossy drips that run down and away.
// @description.zh 像受热的蜡一样融化：底边垂成一道道发亮的蜡滴，往下流走。
// @duration 1.2
// @padding 280
// @events close, quit, minimize

// Drip profile at x (pixels). Returns (length 0..1, position across the drip -1..1).
float2 melt_drips(float x, float cellW, float seed) {
    float ci = floor(x / cellW);
    float2 best = float2(0.0, 0.0);
    for (int k = -1; k <= 1; k++) {
        float c = ci + float(k);
        float3 r = hash32(float2(c * 1.31 + 4.0, seed * 17.0 + 2.0));
        if (r.z < 0.18) continue;                                   // some cells don't drip
        float center = (c + 0.22 + 0.56 * r.x) * cellW;
        float w = mix(0.16, 0.40, r.y) * cellW;                     // half width
        float len = mix(0.30, 1.0, (r.z - 0.18) / 0.82);
        float dx = (x - center) / w;
        float shape = pow(max(1.0 - dx * dx, 0.0), 0.42);           // round tip, steep sides
        float v = len * shape;
        if (v > best.x) best = float2(v, dx);
    }
    return best;
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    if (t <= 0.0) return sampleWindow(tex, u, p);

    float2 W = windowSize(u);
    float H = W.y;
    float top = u.win.y;
    float x = p.x - u.win.x;

    float cellW = clamp(W.x / 9.0, 40.0 * s, 110.0 * s);
    float2 drip = melt_drips(x, cellW, u.seed);
    float sagN = noise(float2(x / W.x * 3.0 + u.seed * 9.0, 0.5));

    float eSag = easeInOutQuad(remap01(t, 0.0, 0.9));
    float eDrip = easeInCubic(remap01(t, 0.04, 1.0));
    float slide = easeInCubic(remap01(t, 0.45, 1.0)) * 0.35 * H;   // everything slips away at the end
    float sag = (0.10 + 0.14 * sagN) * H * eSag;
    float dripLen = drip.x * 1.15 * H * eDrip;

    // y = top + v*H + d(v), d grows toward the bottom edge; invert for v by bisection.
    float lo = 0.0, hi = 1.0;
    float yTop = top + sag * 0.3 + slide;
    float yBot = top + H + sag + dripLen + slide;
    if (p.y < yTop - 1.0 || p.y > yBot + 1.0) return float4(0.0);
    for (int i = 0; i < 14; i++) {
        float v = 0.5 * (lo + hi);
        float y = top + v * H + sag * (0.3 + 0.7 * v) + dripLen * pow(v, 5.0) + slide;
        if (y < p.y) lo = v; else hi = v;
    }
    float v = 0.5 * (lo + hi);

    // Local vertical stretch (dy/dv relative to H): how much this spot is pulled.
    float stretch = (sag * 0.7 + dripLen * 5.0 * pow(v, 4.0)) / H;
    float2 uv = float2(x / W.x, v);
    float4 col = tex.sample(exitSampler, uv, level(clamp(log2(1.0 + stretch) * 1.1, 0.0, 4.0)));

    // Glossy cylinder shading on the drips.
    float onDrip = remap01(stretch, 0.3, 2.0) * step(0.001, drip.x);
    float nx = clamp(drip.y, -1.0, 1.0);
    float diffuse = 0.78 + 0.22 * sqrt(max(1.0 - nx * nx, 0.0)) - 0.12 * nx;
    float spec = pow(max(1.0 - abs(nx + 0.35) * 2.2, 0.0), 3.0) * 0.45;
    col.rgb *= mix(1.0, diffuse, onDrip);
    col.rgb += float3(spec * onDrip) * col.a;
    // A little warmer as it melts.
    col.rgb *= mix(float3(1.0), float3(1.0, 0.94, 0.88), eSag * 0.5);

    float border = min(min(p.x, p.y), min(u.size.x - p.x, u.size.y - p.y));
    float edgeFade = smoothstep(0.0, 90.0 * s, border);
    float fade = 1.0 - easeInQuad(remap01(t, 0.6, 1.0));
    return col * fade * mix(1.0, edgeFade, remap01(t, 0.0, 0.2));
}
