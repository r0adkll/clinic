#!/usr/bin/env bash
# Regenerates Sources/Clinic/Assets.xcassets/AppIcon.appiconset from scripts/clinic-icon.svg.
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="scripts/clinic-icon.svg"
OUT="Sources/Clinic/Assets.xcassets/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# The SVG already carries the macOS icon grid: an 824pt rounded square centred in a
# 1024pt canvas, so every size renders the full canvas onto transparency.
for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" -b none -o "$OUT/icon_${px}.png" "$SRC"
done

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",     "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",     "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",     "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",     "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128",   "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128",   "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256",   "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256",   "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512",   "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512",   "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "wrote $OUT"
