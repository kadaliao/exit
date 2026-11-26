#!/bin/bash
# Builds build/Exit.app.
#   scripts/build-app.sh            release build, signed with a Developer ID if one exists (else ad-hoc)
#   SIGN_IDENTITY=- scripts/...     force ad-hoc signing
#   RELEASE=1 scripts/...           universal binary + secure timestamp (for notarization)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP=build/Exit.app

ARGS=(-c release)
[[ "${RELEASE:-0}" == 1 ]] && ARGS+=(--arch arm64 --arch x86_64)
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/Exit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Effects"
cp "$BIN" "$APP/Contents/MacOS/Exit"
cp Effects/*.metal "$APP/Contents/Resources/Effects/"
cp docs/EFFECTS.md "$APP/Contents/Resources/EFFECTS.md"

# Icon
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/icon-1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.kadaliao.Exit</string>
  <key>CFBundleName</key><string>Exit</string>
  <key>CFBundleDisplayName</key><string>Exit</string>
  <key>CFBundleExecutable</key><string>Exit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi
TS="--timestamp=none"
[[ "${RELEASE:-0}" == 1 ]] && TS="--timestamp"
codesign --force --options runtime $TS --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"
