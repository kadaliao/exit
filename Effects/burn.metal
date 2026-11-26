// @name Burn
// @name.zh 燃烧
// @author Exit
// @description A ragged line of embers eats the window, leaving a charred edge and rising sparks.
// @description.zh 一道参差的火线烧过窗口，留下焦黑的边缘和向上飘的火星。
// @duration 1.25
// @padding 150
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float4 orig = sampleWindow(tex, u, p);
    if (t <= 0.0) return orig;
    if (t >= 1.0) return float4(0.0);

    float S = u.scale;

    // Burn direction, picked by the seed. Fire mostly climbs.
    float pick = fract(u.seed * 5.17);
    float2 dir = pick < 0.45 ? float2(0.0, -1.0)
               : (pick < 0.65 ? float2(1.0, 0.0)
               : (pick < 0.85 ? float2(-1.0, 0.0) : normalize(float2(1.0, -1.0))));
    float2 c = windowCenter(u);
    float2 hs = u.win.zw * 0.5;
    float ext = abs(dir.x) * hs.x + abs(dir.y) * hs.y;
    float s = dot(p - c, dir) + ext;                      // 0 at the starting edge

    // Ragged front: large fbm lobes plus fine crackle.
    float A = 90.0 * S;
    float n = fbm(p / (70.0 * S) + u.seed * 31.0, 4);
    float n2 = noise(p / (12.0 * S) + 7.0);
    float b = s + (n - 0.5) * 2.0 * A + (n2 - 0.5) * 12.0 * S;
    float f = mix(-A - 60.0 * S, 2.0 * ext + A + 60.0 * S, t);
    float e = f - b;                                       // > 0: already burnt (pixels)

    float emberW = 3.5 * S;
    float charW = 11.0 * S;
    float4 col;
    if (e < 0.0) {
        // Scorch: browning ahead of the flame.
        float k = remap01(e, -30.0 * S, 0.0);
        col = orig;
        col.rgb = mix(col.rgb, col.rgb * float3(0.62, 0.40, 0.22), k * k * 0.9);
    } else {
        // Char: blackened rim that crumbles away.
        float ck = remap01(e, emberW * 0.4, emberW + charW);
        float alpha = orig.a * (1.0 - smoothstep(0.5, 1.0, ck));
        float crumble = step(0.35 + 0.6 * ck, noise(p / (3.0 * S) + 3.1));
        alpha *= mix(1.0, crumble, smoothstep(0.3, 0.8, ck));
        float3 charCol = mix(float3(0.13, 0.06, 0.03), float3(0.02, 0.015, 0.01), ck);
        col = premul(charCol, alpha);
    }

    // Glowing ember line (additive), flickering.
    float flick = 0.75 + 0.5 * noise(p / (6.0 * S) + float2(u.time * 9.0, -u.time * 5.0));
    float gate = smoothstep(-14.0 * S, -6.0 * S, e) * (1.0 - smoothstep(18.0 * S, 28.0 * S, e));
    float ember = exp(-abs(e - 1.2 * S) / (2.4 * S)) * gate * orig.a * flick;
    float3 emberCol = mix(float3(1.0, 0.32, 0.04), float3(1.0, 0.86, 0.50), exp(-abs(e - 0.6 * S) / (1.4 * S)));
    float halo = exp(-abs(e) / (9.0 * S)) * smoothstep(-40.0 * S, -24.0 * S, e)
               * (1.0 - smoothstep(30.0 * S, 45.0 * S, e)) * orig.a;
    col.rgb += emberCol * ember * 1.5 + float3(1.0, 0.42, 0.08) * halo * 0.45;
    col.a = clamp(col.a + ember * 0.5 + halo * 0.15, 0.0, 1.0);

    // Sparks rising from the freshly burnt area.
    float env = remap01(t, 0.04, 0.14) * (1.0 - remap01(t, 0.84, 0.99));
    if (env > 0.0 && p.x > u.win.x - 30.0 * S && p.x < u.win.x + u.win.z + 30.0 * S
        && p.y > u.win.y - 140.0 * S && p.y < u.win.y + u.win.w + 10.0 * S) {
        float cellSz = 24.0 * S;
        float rise = u.time * 120.0 * S;
        float2 q = p + float2(0.0, rise);
        float2 base = floor(q / cellSz);
        float3 spark = float3(0.0);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 cid = base + float2(i, j);
                float h = hash21(cid + 0.37);
                if (h < 0.5) continue;
                float2 ps = (cid + 0.15 + 0.7 * hash22(cid * 1.3)) * cellSz - float2(0.0, rise);
                ps.x += sin(u.time * 4.0 + h * 40.0) * 5.0 * S;
                // Only near the flame front (cheap estimate without the noise).
                float es = f - (dot(ps - c, dir) + ext);
                float near = smoothstep(-30.0 * S, 10.0 * S, es) * (1.0 - smoothstep(120.0 * S, 260.0 * S, es));
                float inX = step(u.win.x, ps.x) * step(ps.x, u.win.x + u.win.z);
                float d = length(p - ps);
                float r = (0.7 + 1.1 * hash11(h * 13.0)) * S;
                float tw = 0.6 + 0.4 * sin(u.time * 30.0 + h * 90.0);
                float I = (smoothstep(r * 1.6, 0.0, d) + exp(-d / (r * 2.5)) * 0.35) * near * inX * tw;
                spark += mix(float3(1.0, 0.45, 0.08), float3(1.0, 0.85, 0.45), hash11(h * 7.0)) * I;
            }
        }
        spark *= env;
        col.rgb += spark;
        col.a = clamp(col.a + luminance(spark) * 0.6, 0.0, 1.0);
    }
    return col;
}
