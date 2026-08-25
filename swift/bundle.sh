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
  <key>CFBundleIdentifier</key><string>dev.honato.processx</string>
  <key>CFBundleExecutable</key><string>ProcessX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.2</string>
  <key>CFBundleVersion</key><string>1.2.2</string>
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
ENTITLEMENTS="${ENTITLEMENTS:-Entitlements/ProcessX.entitlements}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  # --options runtime is mandatory for notarization. --timestamp too: without a
  # secure timestamp the signature stops validating when the cert expires.
  # No --deep: Apple deprecated it, and this bundle is a single executable.
  # The entitlements are not optional decoration: --options runtime blocks Apple
  # Events, and ProcessX sends them to read browser tabs. Signing hardened
  # without them ships a build whose tab feature fails with the same error code
  # as a permission denial.
  #
  # One call, not two. Signing the bundle signs its main executable — the
  # signature and the entitlements are embedded in that Mach-O, not bolted on
  # beside it — so the separate pass over Contents/MacOS/ProcessX that used to
  # run first was overwritten by this one every time. It bought nothing and cost
  # an authorization prompt per build, because the Developer ID private key lives
  # in the System keychain and every use of it is gated. The self-test's [signing]
  # section is what makes dropping it safe to assert rather than hope: it reads
  # the *running binary's own* embedded entitlements and fails the build if the
  # apple-events entitlement is missing from a hardened signature.
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" "$APP"
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
  # A stored profile is invisible to `security find-generic-password` and even to
  # `security dump-keychain` — notarytool keeps it in the data-protection
  # keychain. Absence there proves nothing; `notarytool history` is the only
  # reliable existence check. (DiskX 1.0.2 shipped unnotarized on exactly this
  # mistake: the profile existed under another name the whole time.)
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
    STAPLED=yes
  else
    echo "note: notarization did not succeed — signed, but a download will warn" >&2
  fi
elif [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "note: not notarized (no notarytool keychain profile found) — a download will warn"
fi

# The distribution zip.
#
# This has to be built HERE — after stapling — and the script has to be the one
# that builds it. The ticket lives inside the .app, so a zip made before
# `stapler staple` contains an app with no ticket: it still passes `spctl` on
# this machine (Gatekeeper asks Apple online) and still shows the "Apple cannot
# check it" dialog for a user who first launches it offline. Nothing about the
# zip looks wrong. Doing it by hand after the build is one forgotten step away
# from shipping that, so the ordering is encoded instead of remembered.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH_TAG="$(echo "$ARCHES" | tr ' ' '\n' | sort | tr '\n' '-' | sed 's/-$//')"
[ "$ARCH_TAG" = "arm64-x86_64" ] && ARCH_TAG=universal
DIST_ZIP="build/ProcessX-${VERSION}-${ARCH_TAG}.zip"
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP" "$DIST_ZIP"

# Assert on what a user unzips, not on the bundle we still have on disk.
if [ "${STAPLED:-no}" = yes ]; then
  VERIFY_DIR="$(mktemp -d)"
  trap 'rm -rf "$VERIFY_DIR"' EXIT
  ditto -x -k "$DIST_ZIP" "$VERIFY_DIR"
  if xcrun stapler validate "$VERIFY_DIR/ProcessX.app" >/dev/null 2>&1; then
    echo "dist zip verified: extracted app carries its own stapled ticket"
  else
    echo "ERROR: $DIST_ZIP extracts to an app with no stapled ticket." >&2
    echo "       Shipping it would show the Gatekeeper dialog on offline first launch." >&2
    exit 1
  fi
fi

# The distribution disk image.
#
# A .dmg is the format people expect to drag from, and it carries the install
# gesture with it: the window holds the app and a symlink to /Applications, so
# "drag to Applications" is a thing you can do rather than a sentence you have
# to read.
#
# It is built AFTER stapling for the same reason the zip is — the app's ticket
# has to be inside the image — but a stapled app in an unsigned image is still
# not enough. The image is what gets downloaded, so it is what gets quarantined,
# and Gatekeeper assesses it in its own right. It therefore needs its own
# signature and its own stapled ticket; otherwise the app inside opens cleanly
# only once the user has already been through a warning about the disk image
# they opened it from.
if [ "${DMG:-yes}" != "no" ]; then
  DIST_DMG="build/ProcessX-${VERSION}-${ARCH_TAG}.dmg"
  STAGE="$(mktemp -d)"
  rm -f "$DIST_DMG"
  cp -R "$APP" "$STAGE/ProcessX.app"
  ln -s /Applications "$STAGE/Applications"

  # UDZO: compressed and read-only. A read-write image would let the contents —
  # and so the signature — change after notarization.
  hdiutil create -volname "ProcessX $VERSION" -srcfolder "$STAGE" \
                 -ov -format UDZO -quiet "$DIST_DMG"
  rm -rf "$STAGE"

  if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DIST_DMG"
    if [ "${STAPLED:-no}" = yes ] && [ -n "${PROFILE:-}" ]; then
      echo "notarizing the disk image…"
      DOUT="$(xcrun notarytool submit "$DIST_DMG" --keychain-profile "$PROFILE" --wait 2>&1)" || true
      echo "$DOUT" | sed 's/^/  /'
      if grep -qi "status: Accepted" <<<"$DOUT"; then
        xcrun stapler staple "$DIST_DMG"
        # `--type open` with the primary-signature context is how Gatekeeper
        # actually assesses a disk image; `--type execute` is the wrong question
        # to ask about one and answers it misleadingly.
        spctl --assess --type open --context context:primary-signature \
              --verbose=2 "$DIST_DMG" 2>&1 | sed 's/^/  /'
      else
        echo "note: the disk image did not notarize — a download will warn" >&2
      fi
    fi
  fi
fi

echo "built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
echo "dist:  $(cd "$(dirname "$DIST_ZIP")" && pwd)/$(basename "$DIST_ZIP")"
[ -f "${DIST_DMG:-}" ] && echo "dmg:   $(cd "$(dirname "$DIST_DMG")" && pwd)/$(basename "$DIST_DMG")"
