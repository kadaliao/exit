# Writing Exit effects

[中文版](EFFECTS.zh-CN.md)

An Exit effect is one `.metal` file. Drop it into
`~/Library/Application Support/Exit/Effects/` and it shows up in the menu immediately.
Every save recompiles it on the fly; compile errors are shown in Settings → Effects.
A file with the same name as a built-in effect replaces it.

## The contract

You write exactly one Metal Shading Language function. It runs for every pixel of a
transparent canvas that sits on top of the window's position, every frame:

```metal
float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    // ...
}
```

* `p` — the pixel being shaded, in canvas pixels. Origin is the **top-left**, y grows down.
* `u` — uniforms, see below.
* `tex` — a picture of the window (or a stand-in card when Screen Recording is off).
  Never sample it directly; use `sampleWindow(tex, u, pos)` or `sampleWindowUV(tex, uv)`.
* Return a **premultiplied** color: `float4(rgb * a, a)`. `float4(0)` draws nothing.
  `rgb` may exceed `a` to add light on top of what's behind (glows, sparks, flashes).

The canvas is the window rectangle grown by `@padding` points on every side (clipped to
the screen), so you can draw outside the window — particles, shadows, glows.

A prelude is compiled in front of your file. Do not `#include` anything and do not
redefine names from it.

## Header

The file starts with `// @key value` comment lines:

```metal
// @name Old TV
// @name.zh 老电视
// @author Your Name
// @description CRT power-off: collapses to a glowing line, then a dot.
// @description.zh 显像管关机：压成一道亮线，再缩成一个光点。
// @duration 0.62
// @padding 120
// @events close, quit, minimize
```

| key | meaning | default |
|---|---|---|
| `@name`, `@name.zh` | display name (English / Chinese) | file name |
| `@description`, `@description.zh` | one line shown in Settings | — |
| `@duration` | seconds, 0.15 – 6 | 0.7 |
| `@padding` | extra canvas around the window in points, or `screen` for the full screen | 160 |
| `@events` | any of `close`, `quit`, `minimize`, `open` | `close, quit, minimize` |

## Uniforms: `constant Exit& u`

| field | type | meaning |
|---|---|---|
| `u.progress` | float | 0 → 1 over the duration, linear. Ease it yourself. |
| `u.time` | float | seconds since start |
| `u.duration` | float | total seconds (already divided by the user's speed setting) |
| `u.win` | float4 | window rect on the canvas in pixels: `(x, y, width, height)` |
| `u.size` | float2 | canvas size in pixels |
| `u.cursor` | float2 | mouse position on the canvas in pixels when the effect started — usually where the user clicked the close button |
| `u.seed` | float | random 0..1, new on every play — use it to vary direction, colors, layout |
| `u.scale` | float | pixels per point (2 on Retina). Multiply every size by it: `8.0 * u.scale` |
| `u.event` | int | `EVENT_CLOSE`, `EVENT_QUIT`, `EVENT_MINIMIZE` or `EVENT_OPEN` |
| `u.hasSnapshot` | int | 1 = real window picture, 0 = stand-in card |
| `u.corner` | float | window corner radius in pixels |
| `u.accent` | float4 | the user's system accent color (rgb, 1) |

## Helpers from the prelude

Window space

* `float2 toWindowUV(u, p)` — canvas pixel → window uv (0..1 inside the window, top-left origin)
* `float2 fromWindowUV(u, uv)` — window uv → canvas pixel
* `float2 windowCenter(u)`, `float2 windowSize(u)`
* `float4 sampleWindow(tex, u, p)` — window color at canvas pixel `p`; transparent outside
* `float4 sampleWindowUV(tex, uv)` — window color at window uv; transparent outside 0..1
* `sampleWindowSharp(tex, u, p)`, `sampleWindowUVSharp(tex, uv)` — the same at full resolution.
  **Use these inside loops and in branches that differ between neighbouring pixels**
  (particles, shards, cells): the automatic mipmap level is undefined there and smears the
  window's average color far outside the window. Use the plain versions for smooth warps.
* `float windowSDF(u, p)` — signed distance in pixels to the rounded window outline (negative inside)

Shapes: `sdCircle(p, r)`, `sdBox(p, halfSize)`, `sdRoundBox(p, halfSize, r)`, `sdSegment(p, a, b)`, `float2x2 rot(angle)`

Random and noise: `hash11(float)`, `hash21(float2)`, `float2 hash22(float2)`, `float3 hash32(float2)` (all 0..1),
`noise(float2)` (smooth value noise 0..1), `fbm(float2, octaves)`

Easing (input and output 0..1): `easeInQuad`, `easeOutQuad`, `easeInOutQuad`, `easeInCubic`,
`easeOutCubic`, `easeInOutCubic`, `easeInExpo`, `easeOutExpo`, `easeInBack`, `easeOutBack`,
`easeOutElastic`, and `remap01(x, a, b)` which maps `[a, b]` to `[0, 1]` clamped.

Color: `hsv2rgb(float3)`, `palette(t, a, b, c, d)` (cosine palette), `luminance(rgb)`,
`premul(rgb, alpha)`, `over(top, bottom)` (premultiplied compositing)

Constants: `PI`, `TAU`, `EVENT_CLOSE`, `EVENT_OPEN`, `EVENT_MINIMIZE`, `EVENT_QUIT`.

## Rules that make an effect feel right

1. **Seamless start (close / quit / minimize).** The real window disappears the moment the
   effect starts, so at `progress == 0` your output must be exactly `sampleWindow(tex, u, p)`:
   no offset, scale, tint, glow or shadow yet. Bring everything in gradually.
2. **Clean finish.** At `progress == 1` return `float4(0)` everywhere.
3. **Open effects decorate.** For `@events open` the real window stays visible underneath.
   Draw light and accents only (keep alpha low, add light through rgb), start and end
   fully transparent, and never paint the window over itself.
4. **Resolution independent.** Express sizes in points times `u.scale`, and positions
   relative to `u.win`. Windows can be tiny or full-screen, wide or tall.
5. **Fast.** The shader runs for millions of pixels at 120 fps. Keep loops short (dozens of
   iterations, not thousands), skip work early for pixels that can't be affected, and avoid
   per-pixel loops over every particle when a grid lookup will do.
6. **Moving pieces need inverse mapping.** A fragment shader can't push pixels around; for
   each output pixel ask "which piece of the window lands here?". Common tricks: invert a
   transform per piece and test whether the source point belongs to that piece; for
   particles that drift in one direction, march backwards along that direction over the
   candidate cells.

## A complete example

```metal
// @name Fade Away
// @name.zh 淡出
// @description Shrinks slightly and fades out.
// @description.zh 轻轻缩小并淡出。
// @duration 0.35
// @padding 0
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = easeInCubic(u.progress);
    float s = 1.0 - 0.08 * t;                         // scale about the center
    float2 c = windowCenter(u);
    float4 col = sampleWindow(tex, u, c + (p - c) / s);
    return col * (1.0 - t);
}
```

## Trying an effect without closing windows

* Settings → Effects → Preview plays it on a demo window.
* From a terminal: `Exit.app/Contents/MacOS/Exit --check` compiles everything and prints
  errors; `--render-sheet out.png --only my-effect` renders a strip of frames.
