#!/bin/bash
# Builds out/Hello.app, a universal (arm64 + x86_64) app that reports what it sees about where it runs.
# On Intel it runs natively as x86_64; through Maclator it runs its arm64 slice.
set -euo pipefail
cd "$(dirname "$0")"
OUT=out/Hello.app
FONTS=../../app/.fonts
[ -s "$FONTS/InstrumentSerif-Regular.ttf" ] || { echo "run app/build.sh once first to fetch the Paper fonts" >&2; exit 1; }

ICON=.icon/AppIcon.icns
if [ ! -s "$ICON" ] || [ icon.swift -nt "$ICON" ]; then
  rm -rf .icon && mkdir -p .icon/AppIcon.iconset
  swift icon.swift .icon/icon-1024.png 1024 "$FONTS/InstrumentSerif-Regular.ttf"
  for px in 16 32 128 256 512; do
    sips -z $px $px .icon/icon-1024.png --out .icon/AppIcon.iconset/icon_${px}x${px}.png >/dev/null
    sips -z $((px * 2)) $((px * 2)) .icon/icon-1024.png --out .icon/AppIcon.iconset/icon_${px}x${px}@2x.png >/dev/null
  done
  iconutil -c icns .icon/AppIcon.iconset -o "$ICON"
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/Fonts"
mkdir -p .build
SDK="$(xcrun --show-sdk-path)"
for a in arm64 x86_64; do
  swiftc -target $a-apple-macos14.0 -sdk "$SDK" -O -parse-as-library Sources/*.swift -o .build/Hello-$a
done
lipo -create .build/Hello-arm64 .build/Hello-x86_64 -output "$OUT/Contents/MacOS/Hello"
cp "$FONTS"/*.ttf "$OUT/Contents/Resources/Fonts/"
cp "$ICON" "$OUT/Contents/Resources/AppIcon.icns"
# Same version as Maclator (../../VERSION).
VERSION=$(tr -d '[:space:]' < ../../VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
cat > "$OUT/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hello</string>
  <key>CFBundleDisplayName</key><string>Hello</string>
  <key>CFBundleIdentifier</key><string>com.github.pointlessduffin-21.hello-arm</string>
  <key>CFBundleExecutable</key><string>Hello</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>MaclatorVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><true/>
</dict>
</plist>
PL
codesign -f -s - "$OUT" >/dev/null 2>&1
echo "archs: $(lipo -archs "$OUT/Contents/MacOS/Hello")"
echo "built $PWD/$OUT"
