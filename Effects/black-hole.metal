// @name Black Hole
// @name.zh 黑洞
// @author Exit
// @description A singularity opens at the center, twists the window into a spiral and swallows it behind a glowing accretion ring.
// @description.zh 窗口中心裂开一个奇点，把窗口拧成漩涡吞进去，吸积环闪耀后坍缩消失。
// @duration 1.15
// @padding 200
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = u.progress;
    if (t <= 0.0) return sampleWindow(tex, u, p);
    if (t >= 1.0) return float4(0.0);

    float S = u.scale;
    float2 c = windowCenter(u);
    float2 d = p - c;
    float r = length(d);
    float2 dir = r > 0.0 ? d / r : float2(0.0);
    float R = 0.5 * length(u.win.zw);
    float spin = u.seed < 0.5 ? 1.0 : -1.0;

    // Event horizon: opens, holds, then collapses.
    float grow = easeOutCubic(remap01(t, 0.0, 0.45));
    float collapse = 1.0 - easeInCubic(remap01(t, 0.68, 0.90));
    float Rmax = min(0.12 * R, 64.0 * S);
    float Rh = Rmax * grow * collapse;

    // Where does this pixel come from? Pull inward, twist harder near the center, lens around the horizon.
    float pullT = easeInCubic(remap01(t, 0.03, 0.85));
    float pull = 10.0 * pullT;
    float tq = easeInQuad(t);
    float rn = r * (1.0 + pull) / R;                      // radius in original-window units
    float twist = spin * (1.0 * tq + 15.0 * tq * exp(-rn * 3.2));
    float lens = Rh * Rh * 1.6 / max(r, 0.5 * S);
    float rs = r * (1.0 + pull) + lens;
    float2 src = c + (rot(twist) * dir) * rs;
    float4 col = sampleWindow(tex, u, src);

    // Infalling light heats up toward the accent color.
    float3 purple = mix(u.accent.rgb, float3(0.62, 0.36, 1.0), 0.6);
    float heat = remap01(pullT, 0.15, 0.8) * exp(-r / (0.5 * R));
    col.rgb = mix(col.rgb, col.a * mix(purple, float3(1.0, 0.75, 0.95), 0.4), heat * 0.55);
    col *= 1.0 - remap01(t, 0.50, 0.80);
    // Shadow falling into the horizon.
    if (Rh > 0.0) col.rgb *= mix(1.0, smoothstep(Rh, Rh * 2.4 + 6.0 * S, r), 0.75 * grow);

    // The horizon itself.
    float disk = Rh > 0.0 ? 1.0 - smoothstep(Rh - 1.0 * S, Rh + 0.6 * S, r) : 0.0;
    col = over(float4(0.0, 0.0, 0.0, disk), col);

    // Accretion ring with swirling streaks, brighter on the approaching side.
    float env = remap01(t, 0.06, 0.32) * (1.0 + 1.3 * exp(-pow((t - 0.66) / 0.06, 2.0)))
              * (1.0 - remap01(t, 0.78, 0.92));
    if (Rh > 0.0 && env > 0.0) {
        float ringR = Rh * 1.55 + 2.0 * S;
        float w = Rh * 0.30 + 1.5 * S;
        float band = exp(-pow((r - ringR) / w, 2.0));
        float2 nd = rot(u.time * 5.0 * spin) * dir;
        float streak = 0.45 + 0.55 * fbm(nd * 2.6 + float2(r / max(Rh, 1.0) * 1.7, u.seed * 9.0), 3);
        float dop = 0.6 + 0.4 * dot(dir, rot(spin * 1.2) * float2(1.0, 0.0));
        float photon = exp(-pow((r - Rh * 1.04) / (0.9 * S), 2.0)) * 0.9;
        float halo = exp(-max(r - Rh, 0.0) / (Rh * 1.3 + 4.0 * S)) * 0.35 * smoothstep(Rh, Rh + 2.0 * S, r);
        float I = (band * streak * dop * 1.7 + halo + photon) * env;
        float3 hot = mix(purple, float3(1.0, 0.93, 1.0), clamp(pow(band, 3.0) * 0.8 + photon * 0.6, 0.0, 1.0));
        // Partly opaque so the ring stays colored over bright windows.
        col = over(float4(hot * I, clamp(I * 0.7, 0.0, 1.0)), col);
    }

    // Final pinpoint flash.
    float bell = remap01(t, 0.80, 0.88) * (1.0 - remap01(t, 0.88, 1.0));
    float flash = (exp(-r / (5.0 * S)) * 1.5 + exp(-r / (36.0 * S)) * 0.35) * bell;
    col.rgb += mix(purple, float3(1.0), 0.6) * flash;
    col.a = clamp(col.a + flash * 0.4, 0.0, 1.0);
    return col;
}
