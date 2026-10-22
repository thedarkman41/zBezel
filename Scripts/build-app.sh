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

# FreeRDP, built statically by Scripts/build-freerdp.sh. Static on purpose:
# Homebrew's build drags in six ffmpeg libraries, X11, uriparser and jansson,
# and every one of those would have to be copied into the bundle, have its
# install-name rewritten, and be re-signed on a volume that already stamps
# com.apple.FinderInfo onto everything. Archives leave nothing to ship.
FREERDP="$REPO/build/freerdp"
if [[ ! -f "$FREERDP/lib/libfreerdp3.a" ]]; then
    cat >&2 <<'MISSING'
error: FreeRDP is not built.

  Scripts/build-freerdp.sh

Needed for the remote-desktop path — reaching a machine whose login screen the
KVM cannot type at. Builds once, takes a few minutes, lands in build/freerdp.
MISSING
    exit 1
fi

OPENSSL="$(brew --prefix openssl@3)"
JANSSON="$(brew --prefix jansson)"

clang -c -O2 -Wall -o "$OBJ/rdp.o" "$REPO/Sources/rdp.c" \
    -I"$FREERDP/include/freerdp3" -I"$FREERDP/include/winpr3"

clang -c -O2 -Wall -o "$OBJ/rdp_session.o" "$REPO/Sources/rdp_session.c" \
    -I"$FREERDP/include/freerdp3" -I"$FREERDP/include/winpr3"

swiftc -O -parse-as-library \
  -import-objc-header "$REPO/Sources/Bridging.h" \
  -I "$FREERDP/include/freerdp3" -I "$FREERDP/include/winpr3" \
  -o "$BIN/zBezel" \
  "$REPO"/Sources/*.swift \
  "$OBJ/ddc.o" "$OBJ/rdp.o" "$OBJ/rdp_session.o" \
  "$FREERDP/lib/libfreerdp-client3.a" \
  "$FREERDP/lib/libfreerdp3.a" \
  "$FREERDP/lib/libwinpr3.a" \
  "$FREERDP/lib/libremdesk-common.a" \
  "$FREERDP/lib/librdpsnd-common.a" \
  "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" \
  "$JANSSON/lib/libjansson.a" \
  -lz -lresolv \
  -framework IOKit -framework CoreGraphics -framework AppKit -framework SwiftUI -framework WebKit \
  -framework CoreServices -framework Security -framework AudioToolbox \
  -framework AVFoundation -framework CoreAudio -framework CoreMedia

# The agent sources ride along in the bundle so a Windows machine can be set up
# from a clean install without needing this repo.
mkdir -p "$RES/Agent"
cp "$REPO/Agent/BezelAgent.cs" \
   "$REPO/Agent/start-hidden.vbs" \
   "$REPO/Agent/install-service.ps1" \
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
    <key>NSLocalNetworkUsageDescription</key><string>zBezel reaches KVM and display agents on your local network to switch monitor inputs and share the clipboard. This is also required so it keeps local-network access when Beacon Keep Alive restarts it under launchd.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"
# Stamp the version from VERSION rather than carrying it in two places.
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/" "$APP/Contents/Info.plist"

# The file-provider volume stamps com.apple.FinderInfo xattrs that break codesign;
# strip before AND after signing. Use /usr/bin/xattr explicitly — conda's Python
# xattr shadows it on PATH and lacks -r.
/usr/bin/xattr -cr "$APP"

# Sign with a real certificate when one is present, ad-hoc otherwise.
#
# This is not about trust — the certificate is self-signed and Gatekeeper does
# not honour it. It is about what TCC pins. An ad-hoc signature has no identity
# to name, so the designated requirement it generates is the cdhash of the
# binary, and the cdhash changes with every code change. The practical effect
# was that each rebuild silently invalidated the Accessibility grant: the entry
# stayed in the list, still switched on, matching nothing, and the app just
# asked for permission again. With a certificate the requirement becomes
#
#     identifier zBezel and certificate root = H"<cert>"
#
# which is stable across rebuilds, so the grant is given once.
#
# Create the certificate with Scripts/make-signing-cert.sh. Falling back to
# ad-hoc keeps the build working on a machine that has not run it, at the cost
# of re-granting after each build there.
SIGN_ID="zBezel Code Signing"

# Install onto the internal volume, and sign THERE.
#
# The repo lives on /Volumes/Faraday, a file-provider volume that stamps
# com.apple.FinderInfo on anything Finder so much as looks at — and a bundle
# carrying that xattr fails `codesign --verify --strict`:
#
#     resource fork, Finder information, or similar detritus not allowed
#
# TCC validates strictly. So an app sitting there is invalid as far as
# Accessibility is concerned, no matter how correctly it was signed: the grant
# is accepted in System Settings, shows as enabled, and then matches nothing.
# Clearing the xattr does not fix it either, because the volume puts it back
# the next time Finder touches the bundle — which includes the user navigating
# to it in the very file picker used to grant permission.
#
# $HOME is on that same volume, so ~/Applications is no better. /Applications
# is on the internal data volume, is writable without admin, and stays clean.
#
# ditto --norsrc --noextattr copies without carrying the xattrs across, and the
# signature is applied afterwards so it covers what is actually on disk.
INSTALL="/Applications/zBezel.app"
rm -rf "$INSTALL"
/usr/bin/ditto --norsrc --noextattr "$APP" "$INSTALL"

# Beacon Keep-Alive (BeaconKeepAlive.swift) is offered only when our broadcast
# frameworkVersion EQUALS Beacon's current one. That version travels as a
# "<executable>.beaconfw" sidecar the app reads at runtime and sends on every
# heartbeat — Beacon's single source of truth is BeaconVersion.swift, grepped
# here so shell and app agree (the same recipe as Beacon/Scripts/sign-for-beacon.sh).
# Written BEFORE signing so codesign seals it into the bundle and the strict
# verify below still passes; skipped silently if the Beacon repo isn't a sibling
# (the checkbox then just stays greyed, which is correct).
BEACON_FW_FILE="$REPO/../Beacon/Sources/BeaconCore/BeaconVersion.swift"
if [[ -f "$BEACON_FW_FILE" ]]; then
    # head -n1 guards against two literals; `|| true` keeps a no-match grep (exit
    # 1) from aborting the whole script under `set -euo pipefail` AFTER the app is
    # already copied into /Applications but BEFORE it is signed.
    FW_VERSION="$(grep -oE 'framework = "[^"]*"' "$BEACON_FW_FILE" 2>/dev/null | head -n1 | sed -E 's/.*"([^"]*)".*/\1/' || true)"
    if [[ -n "$FW_VERSION" ]]; then
        # Resources/, NOT MacOS/: codesign treats any non-code file beside the
        # executable as an unsigned nested component and fails --strict, so a
        # bundled .app keeps the sidecar among its sealed resources.
        printf '%s' "$FW_VERSION" > "$INSTALL/Contents/Resources/zBezel.beaconfw"
        echo "Beacon framework sidecar: $FW_VERSION"
    fi
fi

if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_ID" --identifier zBezel "$INSTALL"
else
    echo "note: signing ad-hoc — '$SIGN_ID' not in the keychain."
    echo "      Accessibility permission will need re-granting after every build."
    echo "      Run Scripts/make-signing-cert.sh once to fix that."
    codesign --force --sign - --identifier zBezel "$INSTALL"
fi

# Strict verification is the check that actually predicts whether TCC will
# honour a grant, so failing it has to fail the build rather than be discovered
# later as a permission prompt that will not go away.
if ! codesign --verify --deep --strict "$INSTALL" 2>&1; then
    echo "error: $INSTALL does not pass strict verification." >&2
    exit 1
fi

echo "Built: $INSTALL"
