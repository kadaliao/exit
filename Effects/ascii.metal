// @name ASCII
// @name.zh 字符矩阵
// @author Exit
// @description The window turns into phosphor-green characters from the edges inward, then rains away column by column.
// @description.zh 窗口从四周向内变成荧光绿字符，再像字符雨一样一列列落下消失。
// @duration 1.35
// @padding 40
// @events close, quit, minimize

// 5x7 bitmaps, one row per entry, bit 4 = leftmost pixel. Ordered by ink density.
constant uchar ascii_font[10][7] = {
    { 0,  0,  0,  0,  0, 12, 12},   // .
    { 0,  0,  0, 14,  0,  0,  0},   // -
    { 0, 12, 12,  0, 12, 12,  0},   // :
    { 0,  4,  4, 31,  4,  4,  0},   // +
    { 0,  0, 31,  0, 31,  0,  0},   // =
    { 0, 21, 14, 31, 14, 21,  0},   // *
    { 0,  0, 14, 17, 17, 14,  0},   // o
    {25, 26,  2,  4,  8, 11, 19},   // %
    {10, 10, 31, 10, 31, 10, 10},   // #
    {14, 17, 23, 21, 23, 16, 15},   // @
};

// lp: position inside the cell in glyph-pixel units (cell = 6 x 9 glyph pixels).
float ascii_glyph(int g, float2 lp) {
    int gx = int(floor(lp.x)) - 0;
    int gy = int(floor(lp.y)) - 1;
    if (gx < 0 || gx > 4 || gy < 0 || gy > 6) return 0.0;
    uint row = ascii_font[clamp(g, 0, 9)][gy];
    float on = float((row >> uint(4 - gx)) & 1u);
    float2 f = fract(lp) - 0.5;
    float dotShape = smoothstep(0.66, 0.40, length(f));
    return on * mix(1.0, dotShape, 0.45);
}

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    float4 orig = sampleWindow(tex, u, p);
    if (t <= 0.0) return orig;
    if (t >= 1.0) return float4(0.0);
    if (orig.a <= 0.0) return float4(0.0);

    float S = u.scale;
    float gp = 1.45 * S;                                  // glyph pixel size
    float2 cs = float2(6.0, 9.0) * gp;                    // cell size
    float2 g = (p - u.win.xy) / cs;
    float2 cell = floor(g);
    float2 grid = ceil(u.win.zw / cs);
    float2 lp = fract(g) * float2(6.0, 9.0);
    float2 ccPx = u.win.xy + (cell + 0.5) * cs;

    // Average color of the cell via the mip chain.
    float texelsPerPx = float(tex.get_width()) / u.win.z;
    float lod = log2(max(cs.x, cs.y) * texelsPerPx);
    float4 avg = tex.sample(exitSampler, toWindowUV(u, ccPx), level(lod));
    float3 straight = avg.rgb / max(avg.a, 1e-3);
    float lum = luminance(straight);
    // Light windows: dark content becomes ink. Dark windows: bright content becomes ink.
    float4 whole = tex.sample(exitSampler, float2(0.5), level(16.0));
    float globalLum = luminance(whole.rgb / max(whole.a, 1e-3));
    float ink = globalLum > 0.5 ? 1.0 - lum : lum;
    ink = smoothstep(0.04, 0.8, ink);

    // Conversion: from the window edges inward.
    float2 cpx = (cell + 0.5) * cs;
    float edgeDist = min(min(cpx.x, u.win.z - cpx.x), min(cpx.y, u.win.w - cpx.y));
    float edge = clamp(edgeDist / (0.5 * min(u.win.z, u.win.w)), 0.0, 1.0);
    float rnd = hash21(cell + floor(u.seed * 113.0));
    float tc = 0.02 + 0.30 * edge + 0.06 * rnd;
    float k = smoothstep(tc, tc + 0.07, t);

    // Glyph choice: brightness picks density; scrambles while converting.
    float tick = floor(u.time * 28.0);
    int gi = int(clamp(ink, 0.0, 0.999) * 10.0);
    if (t < tc + 0.13) gi = int(hash21(cell + tick * 0.731) * 10.0);
    else if (hash21(cell * 1.13 + tick * 0.37) < 0.025) gi = int(hash21(cell + tick) * 10.0);

    // Rain: a bright head runs down each column and erases it.
    float colRnd = hash11(cell.x * 1.37 + u.seed * 71.0);
    float tf = 0.44 + 0.24 * colRnd;
    const float trail = 7.0;
    float speed = (grid.y + trail + 2.0) / (0.96 - tf);
    float front = (t - tf) * speed - 1.0;
    float dr = front - cell.y;                            // rows since the head passed

    float3 phos = float3(0.30, 1.00, 0.48);
    float3 glyphCol = mix(straight, phos, 0.55) * (0.95 + 0.5 * ink);
    float3 bgCol = straight * 0.10 + float3(0.0, 0.035, 0.015);
    float bgA = 0.93;
    float glyphA = 1.0;

    if (dr >= trail) return float4(0.0);
    if (dr >= 0.0) {
        int rg = int(hash21(cell + floor(u.time * 18.0) * 0.917) * 10.0);
        if (dr < 1.0) {                                  // head
            gi = rg;
            glyphCol = float3(0.85, 1.0, 0.9) * 1.6;
            bgA = 0.93;
        } else {                                         // fading trail
            float f = 1.0 - (dr - 1.0) / (trail - 1.0);
            gi = rg;
            glyphCol = phos * (0.5 + 0.8 * f);
            glyphA = f;
            bgA = 0.93 * f * f;
        }
    }

    float on = ascii_glyph(gi, lp);
    if (dr < 0.0 && ink < 0.08 && hash21(cell * 0.71 + 9.0) < 0.6) on = 0.0;   // keep empty areas airy
    float flash = 1.0 - abs(k * 2.0 - 1.0);
    float3 rgb = mix(bgCol, glyphCol, on) + phos * flash * 0.5 * (0.4 + on);
    float a = max(bgA, on * glyphA);
    // Subtle CRT scanlines.
    rgb *= 0.92 + 0.08 * sin(p.y / S * 2.4);
    float4 asc = premul(rgb, a * orig.a);

    return mix(orig, asc, k);
}
