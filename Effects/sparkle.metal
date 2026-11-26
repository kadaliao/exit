// @name Sparkle
// @name.zh 星光
// @author Exit
// @description A new window arrives with twinkling stars along its edges and a soft ring of light.
// @description.zh 新窗口出现时，边缘闪起点点星光，并荡开一圈柔和的光环。
// @duration 0.95
// @padding 120
// @events open

// Point on the window's rectangle outline for s in [0, 1), plus its outward normal.
float2 sparkle_outline(float s, float2 c, float2 hs, thread float2& normal) {
    float W = hs.x * 2.0, H = hs.y * 2.0;
    float d = fract(s) * 2.0 * (W + H);
    if (d < W) { normal = float2(0.0, -1.0); return c + float2(-hs.x + d, -hs.y); }
    d -= W;
    if (d < H) { normal = float2(1.0, 0.0); return c + float2(hs.x, -hs.y + d); }
    d -= H;
    if (d < W) { normal = float2(0.0, 1.0); return c + float2(hs.x - d, hs.y); }
    d -= W;
    normal = float2(-1.0, 0.0);
    return c + float2(-hs.x, hs.y - d);
}

// Four-point star: two thin rays plus a soft core.
float sparkle_star(float2 d, float size) {
    float2 a = abs(d) / size;
    float rays = exp(-a.x * 7.0) * exp(-a.y * 1.5) + exp(-a.y * 7.0) * exp(-a.x * 1.5);
    float core = exp(-length(d) / (size * 0.16));
    float halo = exp(-length(d) / (size * 0.45)) * 0.35;
    return rays * 1.1 + core * 1.4 + halo;
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    if (t <= 0.0 || t >= 1.0) return float4(0.0);

    float S = u.scale;
    float sd = windowSDF(u, p);
    if (sd > 100.0 * S || sd < -40.0 * S) return float4(0.0);

    float2 c = windowCenter(u);
    float2 hs = u.win.zw * 0.5;
    float3 accentSoft = mix(u.accent.rgb, float3(1.0), 0.35);
    float3 gold = float3(1.0, 0.90, 0.66);

    float3 light = float3(0.0);
    float alpha = 0.0;

    const int N = 44;
    for (int i = 0; i < N; i++) {
        float fi = float(i);
        float h1 = hash11(fi * 1.31 + u.seed * 17.0);
        float h2 = hash11(fi * 2.17 + 5.3 + u.seed * 9.0);
        float h3 = hash11(fi * 3.73 + 1.1 + u.seed * 3.0);
        float birth = h2 * 0.55;
        float life = 0.30 + 0.20 * h3;
        float lt = (t - birth) / life;
        if (lt <= 0.0 || lt >= 1.0) continue;

        float2 n;
        float2 pos = sparkle_outline((fi + 0.8 * h1) / float(N), c, hs, n);
        pos += n * ((3.0 + 46.0 * easeOutCubic(lt) * (0.4 + h3)) * S + (h2 - 0.3) * 10.0 * S);
        float size = (11.0 + 13.0 * h3) * S;
        float2 d = p - pos;
        if (dot(d, d) > size * size * 4.0) continue;
        d = rot(lt * 0.9 * (h1 - 0.5)) * d;

        float tw = sin(PI * lt);
        tw *= tw;
        tw *= 0.7 + 0.3 * sin(u.time * 40.0 * (0.5 + h1) + fi);
        float I = sparkle_star(d, size) * tw;
        light += (h3 > 0.5 ? accentSoft : gold) * I;
        alpha += I;
    }

    // A soft ring of light expanding from the outline.
    float rt = easeOutCubic(remap01(t, 0.0, 0.8));
    float ringD = abs(sd - rt * 55.0 * S - 1.0 * S);
    float ring = (exp(-ringD / (1.6 * S)) + exp(-ringD / (9.0 * S)) * 0.4) * (1.0 - rt) * 0.75 * remap01(t, 0.0, 0.06);
    // A brief highlight tracing the window border.
    float edge = exp(-abs(sd) / (2.5 * S)) * sin(PI * t) * 0.4;
    light += accentSoft * (ring + edge);
    alpha += (ring + edge) * 0.5;

    // Mostly additive light; a little alpha keeps it visible on white windows.
    return float4(light, clamp(alpha * 0.5, 0.0, 0.9));
}
