#!/bin/bash
# Regenerate AppIcon.icns from make_icon.swift. Run when the icon design changes.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf AppIcon.iconset
swift make_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o ../AppIcon.icns
rm -rf AppIcon.iconset
echo "built: $(cd .. && pwd)/AppIcon.icns"
