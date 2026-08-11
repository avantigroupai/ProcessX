#!/bin/bash
# Build ProcessX.app — a menu-bar-only app bundle (no Dock icon, no Xcode project).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ProcessX.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ProcessX" "$APP/Contents/MacOS/ProcessX"

# App icon (regenerate with assets/build_icon.sh). Named AppIcon.icns to match
# CFBundleIconFile below.
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "note: AppIcon.icns missing — run assets/build_icon.sh"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ProcessX</string>
  <key>CFBundleDisplayName</key><string>ProcessX</string>
  <key>CFBundleIdentifier</key><string>local.processx</string>
  <key>CFBundleExecutable</key><string>ProcessX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>1.2.0</string>
  <!-- Liquid Glass requires macOS 26. -->
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- No LSUIElement: this is a real windowed app with a Dock icon.
       (Setting it true would hide the Dock icon and make it menu-bar-only.) -->
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Shown in the Automation permission prompt when ProcessX asks a browser
       for its open tabs (to list tab names and jump to a tab). -->
  <key>NSAppleEventsUsageDescription</key><string>ProcessX lists your browser's open tabs and switches to the one you pick.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

# Stamp a build id (date.time) into CFBundleVersion so the running app can show
# which build it is — the version label in the header changes every build.
BUILD_STAMP="$(date +%Y.%m%d.%H%M)"
plutil -replace CFBundleVersion -string "$BUILD_STAMP" "$APP/Contents/Info.plist"
echo "build stamp: $BUILD_STAMP"

# Signing.
#
# Ad-hoc (`--sign -`) is enough to run locally, but a downloaded ad-hoc bundle is
# refused outright by Gatekeeper. A Developer ID signature alone is not enough
# either — since Catalina, unnotarized downloads still get "Apple cannot check it
# for malicious software". Only signed + notarized + stapled opens cleanly, so
# that is the default whenever the certificate is present.
#
# Override the identity with SIGN_ID, or force the local path with SIGN_ID=-.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  # --options runtime is mandatory for notarization. --timestamp too: without a
  # secure timestamp the signature stops validating when the cert expires.
  # No --deep: Apple deprecated it, and this bundle is a single executable.
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
           "$APP/Contents/MacOS/ProcessX"
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"
  echo "signed: $SIGN_ID"
else
  codesign --force --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"
  echo "signed: ad-hoc (local use only — a download would be blocked)"
fi

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# Notarization. Requires credentials stored once by a human:
#   xcrun notarytool store-credentials notarytool --apple-id you@example.com --team-id TEAMID
# Skipped silently when they are absent, so a plain local build stays fast.
if [ "${NOTARIZE:-auto}" != "no" ] && [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ] \
   && security find-generic-password -s "com.apple.gke.notary.tool" >/dev/null 2>&1; then
  ZIP="build/ProcessX-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarizing (this waits on Apple, typically 1–5 minutes)…"
  if xcrun notarytool submit "$ZIP" --keychain-profile notarytool --wait; then
    xcrun stapler staple "$APP" && echo "stapled: ticket attached, opens with no warning"
  else
    echo "note: notarization failed — the app is signed but a download will warn"
  fi
  rm -f "$ZIP"
elif [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "note: not notarized (no 'notarytool' keychain profile) — a download will warn"
fi

echo "built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
