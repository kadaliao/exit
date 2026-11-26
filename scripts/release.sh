#!/bin/bash
# Builds a universal, signed and notarized Exit-<version>.dmg (plus a .zip) in build/release/.
#
#   VERSION=0.1.0 NOTARY_PROFILE=notary scripts/release.sh
#
# NOTARY_PROFILE is a keychain profile made with `xcrun notarytool store-credentials`.
# Without it everything is signed but not notarized; don't publish that.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. VERSION=0.1.0}"
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ build Exit $VERSION"
RELEASE=1 VERSION="$VERSION" scripts/build-app.sh
APP=build/Exit.app
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -nE 's/^Authority=(Developer ID Application.*)$/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "Exit.app is not signed with a Developer ID" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Exit"

notarize() {
  local result status
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  status=$(sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' <<<"$result")
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization: $status. Details: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
    echo "$result" >&2
    exit 1
  fi
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute "$APP"
fi

echo "▸ dmg"
DMG="$OUT/Exit-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Exit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Exit $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ notarize dmg"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

ditto -c -k --keepParent "$APP" "$OUT/Exit-$VERSION.zip"
(cd "$OUT" && shasum -a 256 ./*.dmg ./*.zip | sed 's| \./| |' > SHA256SUMS)
echo "▸ done"
ls -lh "$OUT"
