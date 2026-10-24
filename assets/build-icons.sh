#!/bin/zsh
# Render assets/icon.svg into the app icon (PlaudeArchiver/AppIcon.icns) and the PNGs the README uses.
# Needs rsvg-convert (brew install librsvg) and iconutil (ships with macOS).
set -e
cd "$(dirname "$0")"

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s icon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) icon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o ../PlaudeArchiver/AppIcon.icns
rsvg-convert -w 512 -h 512 icon.svg -o icon-512.png
rsvg-convert -w 1280 -h 640 banner.svg -o banner.png
echo "Wrote PlaudeArchiver/AppIcon.icns, assets/icon-512.png and assets/banner.png"
