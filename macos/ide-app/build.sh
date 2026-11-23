#!/bin/sh
# macos/ide-app/build.sh OUTDIR — builds OUTDIR/Nihil IDE.app (main.m, the icon from assets/avatar.png).
set -eu
cd "$(dirname "$0")/../.."
out=$1
app="$out/Nihil IDE.app"
version=$(cat VERSION)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -O2 -framework Cocoa -framework WebKit \
    -o "$app/Contents/MacOS/nihil-ide" macos/ide-app/main.m
icons=$(mktemp -d)/nihil.iconset
mkdir -p "$icons"
for s in 16 32 128 256 512; do
    sips -z $s $s assets/avatar.png --out "$icons/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d assets/avatar.png --out "$icons/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/nihil.icns"
rm -rf "$(dirname "$icons")"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nihil IDE</string>
  <key>CFBundleDisplayName</key><string>Nihil IDE</string>
  <key>CFBundleIdentifier</key><string>dev.nihil-lang.ide</string>
  <key>CFBundleExecutable</key><string>nihil-ide</string>
  <key>CFBundleIconFile</key><string>nihil</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
