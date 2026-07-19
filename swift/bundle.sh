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
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundleVersion</key><string>3</string>
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

# Ad-hoc sign so macOS will run it locally without a developer certificate.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"

echo "built: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
