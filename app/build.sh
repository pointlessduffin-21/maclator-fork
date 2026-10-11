#!/bin/bash
# Builds Maclator.app (the launcher) into app/out/.
# Usage: app/build.sh [--bundle] [--install]
#   --bundle   put maclator and the GPU bridge inside the app (Contents/Resources/bin), for a self-contained release
#   --install  copy the app to /Applications
# Needs the Swift toolchain from the Xcode Command Line Tools. The Paper fonts (Instrument Serif, Inter,
# JetBrains Mono; SIL Open Font License) are downloaded from github.com/google/fonts on the first build.
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE=0; INSTALL=0
for a in "$@"; do
  case "$a" in
    --bundle) BUNDLE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
OUT=out/Maclator.app
FONTS=.fonts
GF=https://github.com/google/fonts/raw/main/ofl

mkdir -p "$FONTS"
fetch() { [ -s "$FONTS/$2" ] || curl -fsSL -o "$FONTS/$2" "$GF/$1"; }
fetch instrumentserif/InstrumentSerif-Regular.ttf InstrumentSerif-Regular.ttf
fetch instrumentserif/InstrumentSerif-Italic.ttf InstrumentSerif-Italic.ttf
fetch "inter/Inter%5Bopsz,wght%5D.ttf" "Inter[opsz,wght].ttf"
fetch "jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf" "JetBrainsMono[wght].ttf"

# App icon (icon.swift draws it); regenerated only when the drawing changes.
ICON=.icon/AppIcon.icns
if [ ! -s "$ICON" ] || [ icon.swift -nt "$ICON" ]; then
  rm -rf .icon && mkdir -p .icon/AppIcon.iconset
  swift icon.swift .icon/icon-1024.png 1024
  for px in 16 32 128 256 512; do
    sips -z $px $px .icon/icon-1024.png --out .icon/AppIcon.iconset/icon_${px}x${px}.png >/dev/null
    sips -z $((px * 2)) $((px * 2)) .icon/icon-1024.png --out .icon/AppIcon.iconset/icon_${px}x${px}@2x.png >/dev/null
  done
  iconutil -c icns .icon/AppIcon.iconset -o "$ICON"
fi

swift build -c release --arch x86_64
BIN=$(swift build -c release --arch x86_64 --show-bin-path)/Maclator

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/Fonts"
cp "$BIN" "$OUT/Contents/MacOS/Maclator"
cp "$FONTS"/*.ttf "$OUT/Contents/Resources/Fonts/"
cp ../docs/compatibility.json "$OUT/Contents/Resources/"
cp "$ICON" "$OUT/Contents/Resources/AppIcon.icns"
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Maclator</string>
  <key>CFBundleDisplayName</key><string>Maclator</string>
  <key>CFBundleIdentifier</key><string>com.github.linuxkid473.maclator</string>
  <key>CFBundleExecutable</key><string>Maclator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>x86_64</string></array>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><true/>
</dict>
</plist>
EOF
if [ $BUNDLE = 1 ]; then
  # maclator finds the GPU bridge in a gpu/ directory next to itself (gpu.rs).
  (cd .. && ~/.cargo/bin/cargo build --release -p maclator && gpu/build.sh >/dev/null)
  # In Contents/Resources/bin, sealed as resources by the app's signature:
  # - not Contents/MacOS: on a case-insensitive volume maclator would overwrite Maclator;
  # - not Contents/Helpers: codesign treats that as nested code and refuses an unsigned binary there, while
  #   maclator must stay unsigned (an x86-64 binary may be; once signed, ad hoc or not, it is killed with
  #   SIGKILL at exec). The GPU dylibs are already signed by gpu/build.sh.
  mkdir -p "$OUT/Contents/Resources/bin/gpu"
  cp ../target/release/maclator "$OUT/Contents/Resources/bin/maclator"
  cp ../gpu/out/libmclbridge.dylib ../gpu/out/libmclmetal.dylib "$OUT/Contents/Resources/bin/gpu/"
fi
codesign -f -s - "$OUT" >/dev/null 2>&1
echo "built $PWD/$OUT"
if [ $INSTALL = 1 ]; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST=~/Applications   # not an admin account
  mkdir -p "$DEST"
  rm -rf "$DEST/Maclator.app"
  cp -R "$OUT" "$DEST/"
  echo "installed $DEST/Maclator.app"
fi
