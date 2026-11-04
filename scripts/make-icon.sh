#!/bin/bash
# Rebuilds the artwork layer of the app icon, Resources/AppIcon.icon/Assets/layer.png, from Resources/AppIcon-source.png.
# The source image was generated with Codex (image generation). This script only cleans and sizes it:
#   1. builds a clean mask from the tile's own solid pixels, which drops the faint haze around the edge
#   2. scales the tile slightly past the canvas, so the system's own rounded-square mask supplies the corners
# macOS 26 and later shows apps that lack a layered icon inside a gray plate, so the icon ships as an Icon Composer
# package (Resources/AppIcon.icon). scripts/build-app.sh compiles it with actool, which also writes the .icns used by
# older macOS versions. Needs ImageMagick (`magick`). Safe to run from any directory.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/Resources/AppIcon-source.png"
layer="$root/Resources/AppIcon.icon/Assets/layer.png"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

command -v magick >/dev/null || { echo "ImageMagick (magick) is required: brew install imagemagick" >&2; exit 1; }
[ -f "$src" ] || { echo "Missing $src" >&2; exit 1; }

# Clean silhouette: solid pixels only, small specks removed, smoothed, then pulled in 2 px so no fringe color survives.
magick "$src" -alpha extract -threshold 95% -morphology Open Disk:8 \
  -blur 0x2 -threshold 50% -morphology Erode Disk:2 -blur 0x0.8 "$work/mask.png"
magick "$src" -alpha off "$work/mask.png" -compose CopyOpacity -composite "$work/clean.png"

# Fill the 1024 canvas edge to edge. The tile's own rounded corners fall outside the system mask.
mkdir -p "$(dirname "$layer")"
magick "$work/clean.png" -trim +repage -resize '1100x1100!' -gravity center -crop 1024x1024+0+0 +repage -strip "$layer"
echo "Wrote $layer"
