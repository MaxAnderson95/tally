#!/bin/bash
# Renders every derived icon from the three SVG sources in assets/.
# Requires rsvg-convert and magick (brew install librsvg imagemagick) plus macOS iconutil.
#   assets/tally-icon.svg         macOS app icon on Apple's 1024 grid (824 tile, 100 margin)
#   assets/tally-icon-square.svg  full-bleed tile for platforms that apply their own mask (iOS, Android maskable)
#   assets/tally-glyph.svg        monochrome mark for the menu bar template image
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tally-icons.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p assets/png assets/web
for size in 16 32 64 128 256 512 1024; do
    rsvg-convert -w "$size" -h "$size" assets/tally-icon.svg -o "assets/png/tally-icon-$size.png"
done

iconset="$tmp/Tally.iconset"
mkdir -p "$iconset"
for point in 16 32 128 256 512; do
    cp "assets/png/tally-icon-$point.png" "$iconset/icon_${point}x${point}.png"
    cp "assets/png/tally-icon-$((point * 2)).png" "$iconset/icon_${point}x${point}@2x.png"
done
iconutil -c icns "$iconset" -o assets/Tally.icns

# The favicon is the tile alone, without the macOS grid margin.
sed 's/viewBox="0 0 1024 1024"/viewBox="100 100 824 824"/' assets/tally-icon.svg > assets/web/favicon.svg
rsvg-convert -w 16 -h 16 assets/web/favicon.svg -o "$tmp/favicon-16.png"
rsvg-convert -w 32 -h 32 assets/web/favicon.svg -o "$tmp/favicon-32.png"
magick "$tmp/favicon-16.png" "$tmp/favicon-32.png" assets/web/favicon.ico
rsvg-convert -w 192 -h 192 assets/web/favicon.svg -o assets/web/icon-192.png
rsvg-convert -w 512 -h 512 assets/web/favicon.svg -o assets/web/icon-512.png
rsvg-convert -w 180 -h 180 assets/tally-icon-square.svg -o assets/web/apple-touch-icon.png
rsvg-convert -w 512 -h 512 assets/tally-icon-square.svg -o assets/web/icon-maskable-512.png

# SwiftPM resources must live inside the target, so the menu bar glyph is copied there.
cp assets/tally-glyph.svg Sources/TallyApp/Resources/tally-glyph.svg
