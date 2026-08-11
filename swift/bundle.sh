#!/bin/bash
# Build ProcessX.app — a menu-bar-only app bundle (no Dock icon, no Xcode project).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ProcessX.app"

# Universal by default. macOS 26 is the last release to support Intel Macs, and
# they are still in the supported set — an arm64-only bundle simply fails to
# launch there, which notarization does not catch. Each arch needs its own
# scratch path: SwiftPM reuses auxiliary files across builds and will otherwise
# mix them. Set ARCHES=arm64 for a fast local build.
ARCHES="${ARCHES:-arm64 x86_64}"

BINARIES=()
for ARCH in $ARCHES; do
  echo "==> Building $ARCH"
  swift build -c release --arch "$ARCH" --scratch-path ".build/universal-$ARCH"
  BINARIES+=(".build/universal-$ARCH/$ARCH-apple-macosx/release/ProcessX")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINARIES[@]}" -gt 1 ]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/ProcessX"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/ProcessX"
fi
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/ProcessX")"

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

# Notarization.
#
# Credentials live in a notarytool keychain profile, created once by a human:
#   xcrun notarytool store-credentials <name> --apple-id you@example.com --team-id TEAMID
#
# A profile is per Apple ID + team, NOT per app, so any existing profile for this
# team works — hence the probe rather than a hardcoded name. Set NOTARY_PROFILE
# to pin one, or NOTARIZE=no to skip.
find_notary_profile() {
  local candidates=("${NOTARY_PROFILE:-}" ProcessX-Notary WOS-Notary DiskX-Notary notarytool)
  for p in "${candidates[@]}"; do
    [ -z "$p" ] && continue
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  return 1
}

if [ "${NOTARIZE:-auto}" != "no" ] && [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ] \
   && PROFILE="$(find_notary_profile)"; then
  echo "notary profile: $PROFILE"
  # notarytool only accepts zip/dmg/pkg, never a bare .app directory.
  ZIP="build/ProcessX-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarizing (this waits on Apple, typically 1–5 minutes)…"
  OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)" || true
  echo "$OUT" | sed 's/^/  /'
  rm -f "$ZIP"

  # notarytool can exit 0 on a server-side rejection, so match the status text
  # rather than trusting the exit code alone.
  if grep -q "required agreement is missing or has expired" <<<"$OUT"; then
    echo "BLOCKED: the team's Apple Developer Program agreement is unsigned or expired." >&2
    echo "         Only the Account Holder can clear it: developer.apple.com -> Account -> Agreements" >&2
    exit 1
  elif grep -qi "status: Accepted" <<<"$OUT"; then
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # The string that matters is "source=Notarized Developer ID". A merely signed
    # build reports "Unnotarized Developer ID" and still shows the Gatekeeper
    # dialog — so assert what a first launch actually sees instead of assuming.
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
  else
    echo "note: notarization did not succeed — signed, but a download will warn" >&2
  fi
elif [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "note: not notarized (no notarytool keychain profile found) — a download will warn"
fi

echo "built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
