#!/usr/bin/env bash
# Build Dewey.app (menu-bar only, ad-hoc signed) into <repo>/build/.
# Usage: scripts/bundle.sh            (release build, default .build scratch path)
#        SCRATCH=.build-x scripts/bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app"
SCRATCH="${SCRATCH:-.build}"
OUT="${OUT:-$ROOT/build/Dewey.app}"

cd "$APP_DIR"
swift build -c release --scratch-path "$SCRATCH" --product FlyApp
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/FlyApp" "$OUT/Contents/MacOS/Dewey"

# SwiftPM resource bundle. FlyApp looks it up in Contents/Resources (see AppResources.swift);
# SwiftPM's own Bundle.module accessor would look at the .app root, which codesign rejects.
if [ -d "$BIN_DIR/ConnectomeFly_FlyApp.bundle" ]; then
  cp -R "$BIN_DIR/ConnectomeFly_FlyApp.bundle" "$OUT/Contents/Resources/"
else
  echo "warning: ConnectomeFly_FlyApp.bundle not found in $BIN_DIR" >&2
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>be.0110.dewey</string>
  <key>CFBundleName</key><string>Dewey</string>
  <key>CFBundleDisplayName</key><string>Dewey</string>
  <key>CFBundleExecutable</key><string>Dewey</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$OUT"
codesign --verify --deep --strict "$OUT"
echo "Built $OUT"
