// @name Shatter
// @name.zh 玻璃碎裂
// @author Exit
// @description Cracks like glass from the click point; shards tumble and fall away.
// @description.zh 从点击处像玻璃一样裂开，碎片翻滚着坠落。
// @duration 1.05
// @padding 240
// @events close, quit, minimize

// Jittered grid vertex in pixels. Border vertices stay on the window edge so the
// shards tessellate the window exactly.
float2 shatter_vertex(constant Exit& u, int i, int j, int cols, int rows, float2 cell) {
    float2 jit = (hash22(float2(i, j) * 1.37 + u.seed * 97.0) - 0.5) * 0.72 * cell;
    if (i == 0 || i == cols) jit.x = 0.0;
    if (j == 0 || j == rows) jit.y = 0.0;
    return u.win.xy + float2(i, j) * cell + jit;
}

inline float shatter_cross(float2 a, float2 b, float2 p) {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

inline bool shatter_inside(float2 p, float2 a, float2 b, float2 c) {
    float d1 = shatter_cross(a, b, p), d2 = shatter_cross(b, c, p), d3 = shatter_cross(c, a, p);
    bool neg = (d1 < 0.0) || (d2 < 0.0) || (d3 < 0.0);
    bool pos = (d1 > 0.0) || (d2 > 0.0) || (d3 > 0.0);
    return !(neg && pos);
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float s = u.scale;
    if (t <= 0.0) return sampleWindow(tex, u, p);

    float2 W = windowSize(u);
    float aspect = W.x / W.y;
    int cols = clamp(int(round(sqrt(28.0 * aspect))), 3, 9);
    int rows = clamp(int(round(28.0 / float(cols))), 3, 7);
    float2 cell = W / float2(cols, rows);
    float2 impact = clamp(u.cursor, u.win.xy + 6.0 * s, u.win.xy + W - 6.0 * s);
    float maxDist = length(W);
    float dur = u.duration;
    const float startT = 0.075;
    float bound = length(cell) * 0.95;

    // Cracks race out from the impact point, then fade once shards fly.
    float crackR = maxDist * easeOutCubic(remap01(t, 0.0, 0.07));
    float crackVis = remap01(t, 0.0, 0.02) * (1.0 - remap01(t, 0.16, 0.34));

    // Soft fade near the canvas border so falling shards never get cut off hard.
    float border = min(min(p.x, p.y), min(u.size.x - p.x, u.size.y - p.y));
    float edgeFade = smoothstep(0.0, 70.0 * s, border);

    // Cull rows/columns no shard can reach yet: shards drift sideways at most ~370pt/s and
    // never rise more than ~65pt (v_up^2 / 2g), so only nearby cells need testing.
    float Tmax = max(t - startT, 0.0) * dur;
    float xReach = 370.0 * s * Tmax + bound + cell.x;
    int i0 = max(0, int(floor((p.x - u.win.x - xReach) / cell.x)));
    int i1 = min(cols - 1, int(floor((p.x - u.win.x + xReach) / cell.x)));
    int j1 = min(rows - 1, int(floor((p.y - u.win.y + 65.0 * s + bound + cell.y) / cell.y)));
    if (i1 < i0 || j1 < 0) return float4(0.0);

    for (int j = 0; j <= j1; j++) {
        for (int i = i0; i <= i1; i++) {
            float2 cid = float2(i, j);
            bool diag = hash21(cid + u.seed * 31.7) > 0.5;
            float2 o = u.win.xy + cid * cell;
            for (int k = 0; k < 2; k++) {
                // Unjittered triangle (for a stable pivot) — exact vertices fetched on demand.
                float2 a0, b0, c0;
                if (!diag) {
                    a0 = o; b0 = o + float2(cell.x, 0.0); c0 = o + (k == 0 ? cell : float2(0.0, cell.y));
                    if (k == 1) { b0 = o + cell; }
                } else {
                    if (k == 0) { a0 = o; b0 = o + float2(cell.x, 0.0); c0 = o + float2(0.0, cell.y); }
                    else        { a0 = o + float2(cell.x, 0.0); b0 = o + cell; c0 = o + float2(0.0, cell.y); }
                }
                float2 pivot = (a0 + b0 + c0) / 3.0;

                float3 r = hash32(cid * 1.73 + float(k) * 13.1 + u.seed * 53.0);
                float delay = startT + 0.30 * length(pivot - impact) / maxDist + 0.05 * r.x;
                float T = max(t - delay, 0.0) * dur;

                float2 dir = normalize(pivot - impact + float2(0.01, 0.013));
                float2 vel = dir * mix(70.0, 300.0, r.y) * s
                           + float2((r.z - 0.5) * 140.0, -mix(30.0, 240.0, r.x)) * s;
                float2 disp = vel * T + float2(0.0, 0.5 * 2300.0 * s * T * T);
                float2 d = p - (pivot + disp);
                if (dot(d, d) > bound * bound) continue;
                float ang = (r.z - 0.5) * 7.0 * T;
                float flip = cos(mix(3.0, 10.0, r.y) * T);
                d = rot(-ang) * d;
                d.x /= (abs(flip) < 0.05 ? 0.05 * sign(flip + 1e-4) : flip);
                float2 q = pivot + d;
                if (dot(q - pivot, q - pivot) > bound * bound) continue;

                // Exact jittered triangle.
                float2 v00 = shatter_vertex(u, i, j, cols, rows, cell);
                float2 v10 = shatter_vertex(u, i + 1, j, cols, rows, cell);
                float2 v01 = shatter_vertex(u, i, j + 1, cols, rows, cell);
                float2 v11 = shatter_vertex(u, i + 1, j + 1, cols, rows, cell);
                float2 A, B, C;
                if (!diag) {
                    if (k == 0) { A = v00; B = v10; C = v11; } else { A = v00; B = v11; C = v01; }
                } else {
                    if (k == 0) { A = v00; B = v10; C = v01; } else { A = v10; B = v11; C = v01; }
                }
                if (!shatter_inside(q, A, B, C)) continue;

                // Explicit LOD: sampling inside the loop is non-uniform control flow.
                float4 col = tex.sample(exitSampler, toWindowUV(u, q), level(0.0));
                if (col.a <= 0.001) continue;

                float edge = min(min(sdSegment(q, A, B), sdSegment(q, B, C)), sdSegment(q, C, A));
                float moving = smoothstep(0.0, 0.06, T);

                // Glass shading: darker when seen from behind, a glint as it tumbles.
                float back = flip < 0.0 ? 1.0 : 0.0;
                col.rgb *= mix(1.0, 0.72 + 0.28 * abs(flip), moving) * (1.0 - 0.18 * back * moving);
                float glint = pow(max(sin(ang * 1.7 + flip * 2.0 + r.x * 6.0), 0.0), 12.0) * 0.55 * moving;
                col.rgb += float3(glint) * col.a;
                // Bright rim on moving shards.
                float rim = (1.0 - smoothstep(0.6 * s, 1.8 * s, edge)) * moving;
                col.rgb = mix(col.rgb, float3(col.a), rim * 0.55);

                // Crack lines on still-attached shards.
                float cracked = step(length(q - impact), crackR) * crackVis * (1.0 - moving);
                float line = 1.0 - smoothstep(0.35 * s, 1.3 * s, edge);
                float halo = exp(-edge / (3.0 * s)) * 0.25;
                col.rgb = mix(col.rgb, float3(col.a), clamp((line + halo) * cracked, 0.0, 1.0));

                float fade = 1.0 - remap01(T / dur, 0.45 + 0.25 * r.y, 0.92);
                fade *= 1.0 - remap01(t, 0.9, 1.0);
                return col * fade * mix(1.0, edgeFade, moving);
            }
        }
    }
    return float4(0.0);
}
