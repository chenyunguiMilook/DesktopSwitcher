#!/bin/bash
# Builds DesktopSwitcher.app into ./build.
#
#   ./build.sh              release build
#   ./build.sh debug        debug build
#   ./build.sh --install    release build, then copy into /Applications
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug)      CONFIG=debug ;;
    release)    CONFIG=release ;;
    --install)  INSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME=DesktopSwitcher
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/"$APP_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>DesktopSwitcher</string>
    <key>CFBundleDisplayName</key>           <string>Desktop Switcher</string>
    <key>CFBundleIdentifier</key>            <string>com.chenyungui.desktopswitcher</string>
    <key>CFBundleExecutable</key>            <string>DesktopSwitcher</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- No Dock icon, no app switcher entry: this is a background widget. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
PLIST

# Signing identity decides whether the Accessibility grant survives a rebuild.
# An ad-hoc signature hashes the binary, so every rebuild looks like a different app to
# TCC and the user has to re-authorise. A real certificate keeps the identity stable, so
# prefer one automatically unless CODESIGN_IDENTITY overrides the choice.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$CODESIGN_IDENTITY"
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')
  [[ -z "$IDENTITY" ]] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi

echo "==> codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null

if [[ "$IDENTITY" == "-" ]]; then
  echo "    ⚠️  ad-hoc signature: the Accessibility grant will be revoked on every rebuild."
  echo "        Set CODESIGN_IDENTITY to a real certificate to keep it stable."
fi

if [[ "$INSTALL" == "1" ]]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "installed: /Applications/$APP_NAME.app"
else
  echo "built: $APP"
fi
