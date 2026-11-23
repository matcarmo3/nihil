#!/bin/sh
# macos/ide-app/build.sh OUTDIR — builds OUTDIR/Nihil IDE.app (main.m and nihil.icns).
# nihil.icns and ide/static/icon-*.png come from assets/avatar.png, made with macos/ide-app/icons.py.
set -eu
cd "$(dirname "$0")/../.."
out=$1
app="$out/Nihil IDE.app"
version=$(cat VERSION)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -O2 -framework Cocoa -framework WebKit \
    -o "$app/Contents/MacOS/nihil-ide" macos/ide-app/main.m
cp macos/ide-app/nihil.icns "$app/Contents/Resources/nihil.icns"
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
