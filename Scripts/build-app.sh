#!/bin/zsh
# Build zBezel.app into build/. Ad-hoc signed with a stable identifier.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO/Sources/BezelApp.swift" ]] || { echo "not the Bezel repo: $REPO" >&2; exit 1; }

VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)"
APP="$REPO/build/zBezel.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
OBJ="$REPO/build/obj"
rm -rf "$APP"
mkdir -p "$BIN" "$RES" "$OBJ"

# The DDC/AUX transport is C: IOKit's i2c headers are absent from the Swift module map.
clang -c -O2 -Wall -o "$OBJ/ddc.o" "$REPO/Sources/ddc.c"

swiftc -O -parse-as-library \
  -import-objc-header "$REPO/Sources/Bridging.h" \
  -o "$BIN/zBezel" \
  "$REPO"/Sources/*.swift \
  "$OBJ/ddc.o" \
  -framework IOKit -framework CoreGraphics -framework AppKit -framework SwiftUI

# The agent sources ride along in the bundle so a Windows machine can be set up
# from a clean install without needing this repo.
mkdir -p "$RES/Agent"
cp "$REPO/Agent/BezelAgent.cs" \
   "$REPO/Agent/start-hidden.vbs" \
   "$REPO/Agent/install-service.ps1" \
   "$REPO/Agent/run-agent.ps1" \
   "$RES/Agent/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>zBezel</string>
    <key>CFBundleIdentifier</key><string>com.darkstar.zBezel</string>
    <key>CFBundleName</key><string>zBezel</string>
    <key>CFBundleDisplayName</key><string>zBezel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"
# Stamp the version from VERSION rather than carrying it in two places.
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/" "$APP/Contents/Info.plist"

# The file-provider volume stamps com.apple.FinderInfo xattrs that break codesign;
# strip before AND after signing. Use /usr/bin/xattr explicitly — conda's Python
# xattr shadows it on PATH and lacks -r.
/usr/bin/xattr -cr "$APP"
codesign --force --sign - --identifier zBezel "$APP"
/usr/bin/xattr -cr "$APP" 2>/dev/null || true

echo "Built: $APP"
