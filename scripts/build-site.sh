#!/bin/bash
# Builds the website (site/) into OUT_DIR, pointing its download buttons at the DMG of the
# latest GitHub release.
#
#   scripts/build-site.sh [OUT_DIR]        default: build/site
#
# Needs the GitHub CLI, signed in (or GH_TOKEN set, as in the Site workflow). Preview with
#   python3 -m http.server -d build/site
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-build/site}
REPO=${GITHUB_REPOSITORY:-kadaliao/exit}

IFS=$'\t' read -r TAG URL DMG_URL DMG_BYTES < <(
  gh release view -R "$REPO" --json tagName,url,assets --jq \
    '[.tagName, .url, (.assets[] | select(.name | test("^Exit-.*\\.dmg$")) | .url, .size)] | @tsv'
)
[[ -n "${DMG_URL:-}" ]] || { echo "the latest release of $REPO has no Exit-<version>.dmg" >&2; exit 1; }
VERSION=${TAG#v}
DMG_MB=$(awk -v b="$DMG_BYTES" 'BEGIN { printf "%.1f", b / 1000000 }')   # Finder's megabytes

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R site/. "$OUT/"
sed -i.bak \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__DMG_URL__|$DMG_URL|g" \
  -e "s|__DMG_MB__|$DMG_MB|g" \
  -e "s|__RELEASE_URL__|$URL|g" \
  "$OUT/index.html"
rm "$OUT/index.html.bak"
if grep -q '__[A-Z_]*__' "$OUT/index.html"; then
  echo "unfilled placeholders left in index.html:" >&2
  grep -o '__[A-Z_]*__' "$OUT/index.html" | sort -u >&2
  exit 1
fi
echo "▸ site for Exit $VERSION ($DMG_MB MB dmg) → $OUT"
