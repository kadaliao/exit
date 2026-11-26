# Exit

**Give every window a proper exit.** Exit is a free, open-source macOS menu-bar app that
plays a GPU animation right where a window closes — it shatters, burns, melts, peels off
like a sticker, gets sucked into your cursor, or turns to dust. Windows can make an
entrance too.

[中文说明](README.zh-CN.md)

![Twelve closing effects, frame by frame](docs/images/effects.jpg)

## Highlights

- **14 built-in effects**, rendered with Metal at your display's refresh rate:
  Old TV, Pixel Dissolve, ASCII, Glitch, Burn, Black Hole, Dust, Shatter, Sticker Peel,
  Confetti, Melt, Vacuum — plus Glint and Sparkle for windows that open.
- **The true last frame.** When you press ⌘W / ⌘Q / ⌘M or click a window's close button,
  Exit holds the input for a few milliseconds, photographs the window as it is, then lets
  it go. The animation starts from exactly what you saw — no stale picture, no grey box.
- **More than closing.** Assign effects separately to closing a window, quitting an app,
  opening a window and minimizing. Pick one, shuffle, or turn any of them off.
- **Effects are just files.** Each effect is one Metal shader in
  `~/Library/Application Support/Exit/Effects/`. Edit it and it recompiles the moment you
  save. Share it by sending the file. See the [authoring guide](docs/EFFECTS.md).
- **Describe an effect, get an effect.** Type "the window pops like a balloon" and Claude
  writes the shader. Exit compiles it, renders test frames to check it starts seamlessly,
  ends cleanly and runs fast, sends any problems back to Claude, and plays the result.
  Works with your local Claude Code login or an Anthropic API key.
- **Stays out of the way.** Click-through overlays that never take focus, multiple
  displays, Spaces, full-screen apps, per-app exclusions, minimum window size, and it goes
  still when Reduce Motion is on.

## Install

Requires macOS 14 or later (Apple Silicon and Intel).

```sh
brew install --cask kadaliao/tap/exit
```

Or download the DMG from [Releases](https://github.com/kadaliao/exit/releases/latest).

Or build it yourself:

```sh
git clone https://github.com/kadaliao/exit && cd exit
scripts/build-app.sh
open build/Exit.app
```

## Permissions

| Permission | Why |
|---|---|
| Accessibility (required) | To notice windows opening, closing and minimizing, and to briefly hold ⌘W / ⌘Q / ⌘M and close-button clicks for the precise last frame. Only those shortcuts are examined; every other key passes straight through. |
| Screen Recording (optional) | So the animation starts from the window's real picture. Without it Exit animates a card with the app's icon. |

Window pictures live in memory for a few seconds and are never written to disk or sent
anywhere. Exit makes no network requests, except when you ask it to generate an effect
with Claude.

## Making effects

```metal
// @name Fade Away
// @name.zh 淡出
// @duration 0.35
// @events close, quit, minimize

float4 effect(float2 p, constant Exit& u, texture2d<float> tex) {
    float t = easeInCubic(u.progress);
    float2 c = windowCenter(u);
    return sampleWindow(tex, u, c + (p - c) / (1.0 - 0.08 * t)) * (1.0 - t);
}
```

Save that as `fade-away.metal` in the Effects folder and it's in the menu. The
[guide](docs/EFFECTS.md) covers the uniforms, the helper library and the rules that make
an effect feel right. Command-line tools for authors:

```sh
Exit.app/Contents/MacOS/Exit --check                       # compile everything
Exit.app/Contents/MacOS/Exit --validate --only my-effect   # seamless start, clean end, speed
Exit.app/Contents/MacOS/Exit --render-sheet out.png --only my-effect
Exit.app/Contents/MacOS/Exit --bench
```

## How it works

- `WindowTracker` follows every app's windows through Accessibility notifications on its
  own thread, so a hung app can't stall anything.
- `EventInterceptor` is a session event tap that only looks at ⌘W / ⌘Q / ⌘M and clicks
  on traffic-light buttons, holding them until `SnapshotService` (ScreenCaptureKit) has the
  frame or 160 ms pass.
- `OverlayPanel` is a click-through, non-activating panel with a Metal layer, drawn
  above where the window was. A small pool is kept warm so the first frame lands
  immediately.
- Effects are compiled from source at runtime (`device.makeLibrary(source:)`), which is
  what makes hot reload and AI generation possible.

## License

MIT
