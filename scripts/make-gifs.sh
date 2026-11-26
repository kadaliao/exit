#!/bin/bash
# Renders the built-in effects in Effects/ to docs/effects/<id>.gif for the README.
#
#   scripts/make-gifs.sh                 every effect
#   scripts/make-gifs.sh shatter glint   just these
#
# Needs ffmpeg, gifski and gifsicle (brew install ffmpeg gifski gifsicle).
# Intermediate frames go to build/gifs/.
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in ffmpeg gifski gifsicle; do
  command -v "$tool" >/dev/null || { echo "$tool not found: brew install $tool" >&2; exit 1; }
done

# Stage in pixels at scale 2: the 720x460 pt demo window on a 4:3 wallpaper with 280 pt
# (the largest @padding) on every side, so particles thrown far out are never cut off.
SCALE=2
STAGE_W=2720 STAGE_H=2040
WIN_W=1440 WIN_H=920
WIN_X=$(( (STAGE_W - WIN_W) / 2 )) WIN_Y=$(( (STAGE_H - WIN_H) / 2 ))
OUT_W=800 OUT_H=$(( OUT_W * STAGE_H / STAGE_W ))
FPS=30
QUALITY=${QUALITY:-100}

# Frames of plain window / plain wallpaper around each effect.
CLOSE_HOLD=$(( FPS * 6 / 10 )) CLOSE_EMPTY=$(( FPS * 4 / 10 ))
OPEN_EMPTY=$(( FPS * 3 / 10 )) OPEN_HOLD=$(( FPS * 8 / 10 ))
# gifski leaves pixels alone when they change only slightly, so a shadow or glow that fades
# slowly leaves a ghost on the wallpaper. Each GIF is encoded in pieces that start with a full
# frame: one per phase, and one every KEY_EVERY frames while an effect plays. gifsicle -O3
# then drops whatever those full frames repeat, so they cost little.
KEY_EVERY=$(( FPS / 10 ))

WORK=build/gifs
DEST=docs/effects
DOWNSCALE="scale=$OUT_W:$OUT_H:flags=lanczos+accurate_rnd+full_chroma_int,format=rgb24"

if [[ $# -gt 0 ]]; then IDS=("$@"); else
  IDS=()
  for f in Effects/*.metal; do
    id=$(basename "$f" .metal)
    [[ "$id" == prelude ]] || IDS+=("$id")
  done
fi
for id in "${IDS[@]}"; do
  [[ -f "Effects/$id.metal" ]] || { echo "no such effect: Effects/$id.metal" >&2; exit 1; }
done

is_opening() {   # an effect that only plays when a window opens
  local events
  events=$(sed -nE 's|^// @events[[:space:]]+(.*)$|\1|p' "Effects/$1.metal" | head -1)
  [[ "$events" == *open* && "$events" != *close* && "$events" != *quit* && "$events" != *minimize* ]]
}

canvas() {   # canvas dir field: one number from the renderer's meta.json
  plutil -extract "canvas.$2" raw -o - "$1/meta.json" | sed 's/\..*//'
}

render() {   # render file.metal dir [args]: a transparent PNG sequence plus meta.json
  local src=$1 dir=$2; shift 2
  rm -rf "$dir"
  "$BIN" --render-sequence "$dir" --file "$src" \
    --stage "${STAGE_W}x${STAGE_H}" --rect "$WIN_X,$WIN_Y,$WIN_W,$WIN_H" \
    --scale "$SCALE" --fps "$FPS" "$@" >/dev/null
}

# composite in_dir out_dir [layer.png]: lays a rendered sequence on the wallpaper (over an
# optional full-stage layer), downscales it and writes numbered PNGs.
composite() {
  local in=$1 out=$2 x y n=1 base="[0:v]"
  local inputs=(-loop 1 -framerate "$FPS" -i "$WORK/wallpaper.png")
  x=$(canvas "$in" x); y=$(canvas "$in" y)
  if [[ -n "${3:-}" ]]; then
    inputs+=(-loop 1 -framerate "$FPS" -i "$3"); base="[0:v][1:v]overlay=format=rgb[base];[base]"; n=2
  fi
  inputs+=(-framerate "$FPS" -i "$in/%04d.png")
  rm -rf "$out"; mkdir -p "$out"
  ffmpeg -v error -y "${inputs[@]}" -filter_complex \
    "$base[$n:v]overlay=x=$x:y=$y:format=rgb:shortest=1,$DOWNSCALE" -start_number 0 "$out/%04d.png"
  local want have
  want=$(ls "$in"/*.png | wc -l); have=$(ls "$out"/*.png | wc -l)
  (( want == have )) || { echo "composite $in: got $have of $want frames" >&2; exit 1; }
}

repeat() { local i; for (( i = 0; i < $2; i++ )); do echo "$1"; done; }

# encode list.txt out.gif key...: one gifski piece per key frame index (ascending), joined
# losslessly with gifsicle.
encode() {
  local list=$1 out=$2; shift 2
  local files=() starts=() pieces=() line k i n last=-2 piece
  while IFS= read -r line; do files+=("$line"); done < "$list"
  n=${#files[@]}
  for k in "$@"; do   # gifski needs at least two frames per piece
    if (( k - last >= 2 && n - k >= 2 )); then starts+=("$k"); last=$k; fi
  done
  starts+=("$n")
  for (( i = 0; i + 1 < ${#starts[@]}; i++ )); do
    piece="${list%.txt}-$i.gif"
    gifski --quiet --fps "$FPS" --width "$OUT_W" --quality "$QUALITY" \
      --repeat 0 --no-sort -o "$piece" "${files[@]:${starts[i]}:$(( starts[i + 1] - starts[i] ))}"
    pieces+=("$piece")
  done
  gifsicle --no-warnings -O3 --loopcount=forever "${pieces[@]}" -o "$out"
}

echo "▸ build"
swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/Exit"

rm -rf "$WORK"
mkdir -p "$WORK" "$DEST"
if [[ $# -eq 0 ]]; then   # drop GIFs of effects that no longer exist
  for g in "$DEST"/*.gif; do
    if [[ -e "$g" && ! -f "Effects/$(basename "$g" .gif).metal" ]]; then rm "$g"; fi
  done
fi

echo "▸ wallpaper and window"
# Diagonal gradient, like the effect thumbnails in Settings.
t="(X/W+Y/H)/2"
ffmpeg -v error -y -f lavfi -i "color=c=black:s=${STAGE_W}x${STAGE_H}:d=1,format=rgb24" \
  -vf "geq=r='61+59*$t':g='92-10*$t':b='140-7*$t'" -frames:v 1 "$WORK/wallpaper.png"
ffmpeg -v error -y -i "$WORK/wallpaper.png" -vf "$DOWNSCALE" "$WORK/empty.png"

# The plain window and its shadow, from a pass-through effect whose canvas is the whole stage,
# so the shadow isn't cut off. Frame 0 of every closing effect looks like this.
cat > "$WORK/window.metal" <<'METAL'
// @name Window
// @duration 0.1
// @padding screen
// @events close
float4 effect(float2 p, constant Exit& u, texture2d<float> tex) { return sampleWindow(tex, u, p); }
METAL
render "$WORK/window.metal" "$WORK/window" --shadow
WINDOW_LAYER="$WORK/window/0000.png"
[[ "$(canvas "$WORK/window" w)x$(canvas "$WORK/window" h)" == "${STAGE_W}x${STAGE_H}" ]] ||
  { echo "the window layer should cover the whole stage" >&2; exit 1; }
ffmpeg -v error -y -i "$WORK/wallpaper.png" -i "$WINDOW_LAYER" -filter_complex \
  "[0:v][1:v]overlay=format=rgb,$DOWNSCALE" -frames:v 1 "$WORK/window.png"

echo "▸ effects"
for id in "${IDS[@]}"; do
  raw="$WORK/$id/raw" frames="$WORK/$id/frames" list="$WORK/$id/list.txt"
  if is_opening "$id"; then
    # The renderer draws only the decoration; the window appears under it. The loop starts
    # on the finished window so a paused or loading GIF still shows one.
    render "Effects/$id.metal" "$raw" --event open
    composite "$raw" "$frames" "$WINDOW_LAYER"
    { repeat "$WORK/window.png" "$OPEN_HOLD"
      repeat "$WORK/empty.png" "$OPEN_EMPTY"
      ls "$frames"/*.png; } > "$list"
    n=$(wc -l < "$list")
    keys=(0 "$OPEN_HOLD")
    for (( k = OPEN_HOLD + OPEN_EMPTY; k < n; k += KEY_EVERY )); do keys+=("$k"); done
  else
    # Frame 0 is the untouched window, so the held window stands in for it.
    render "Effects/$id.metal" "$raw" --shadow
    composite "$raw" "$frames"
    { repeat "$WORK/window.png" "$CLOSE_HOLD"
      ls "$frames"/*.png | tail -n +2
      repeat "$WORK/empty.png" "$CLOSE_EMPTY"; } > "$list"
    n=$(wc -l < "$list")
    keys=(0)
    for (( k = CLOSE_HOLD; k < n - CLOSE_EMPTY; k += KEY_EVERY )); do keys+=("$k"); done
    keys+=($(( n - CLOSE_EMPTY )))
  fi
  encode "$list" "$DEST/$id.gif" "${keys[@]}"
  printf '  %-16s %3d frames  %4d KB\n' "$id" "$(gifsicle --info "$DEST/$id.gif" | sed -nE '1s/.* ([0-9]+) images.*/\1/p')" \
    $(( $(stat -f %z "$DEST/$id.gif") / 1024 ))
done
echo "▸ done"
