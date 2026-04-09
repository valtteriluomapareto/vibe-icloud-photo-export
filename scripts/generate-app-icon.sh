#!/bin/bash
# Generate a complete macOS AppIcon.appiconset from a single square image.
#
# Usage:
#   scripts/generate-app-icon.sh
#   scripts/generate-app-icon.sh path/to/source-image
#   scripts/generate-app-icon.sh path/to/source-image path/to/AppIcon.appiconset
#   scripts/generate-app-icon.sh path/to/source-image path/to/AppIcon.appiconset path/to/website-icon.png
#
# Notes:
# - Keep the master artwork square and unmasked. Apple's current HIG says
#   iOS, iPadOS, and macOS icons use square source layers and the system
#   applies the final rounded-rectangle masking on supported platforms.
# - Asset catalogs remain a supported delivery path. Apple's Xcode
#   distribution docs say the system applies the current icon treatment to
#   asset-catalog app icons for you.
# - Older macOS releases can still render the shipped artwork more directly,
#   so we keep one future-facing square master instead of baking rounded
#   corners into the source image.
#
# Relevant docs:
# - https://developer.apple.com/design/human-interface-guidelines/app-icons
# - https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/

set -euo pipefail

SOURCE_IMAGE="${1:-}"
APPICON_DIR="${2:-photo-export/Assets.xcassets/AppIcon.appiconset}"
WEBSITE_ICON="${3:-website/public/app-icon.png}"

if [[ -z "$SOURCE_IMAGE" ]]; then
  shopt -s nullglob
  default_sources=(design/app-icon-master.*)
  shopt -u nullglob

  if (( ${#default_sources[@]} == 0 )); then
    echo "Error: no default source image found at design/app-icon-master.*"
    exit 1
  fi

  if (( ${#default_sources[@]} > 1 )); then
    echo "Error: multiple default source images found:"
    printf '  %s\n' "${default_sources[@]}"
    echo "Pass the source image path explicitly."
    exit 1
  fi

  SOURCE_IMAGE="${default_sources[0]}"
fi

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  echo "Error: source image not found: $SOURCE_IMAGE"
  exit 1
fi

if [[ ! -d "$APPICON_DIR" ]]; then
  echo "Error: app icon set not found: $APPICON_DIR"
  exit 1
fi

WEBSITE_ICON_DIR=$(dirname "$WEBSITE_ICON")

if [[ ! -d "$WEBSITE_ICON_DIR" ]]; then
  echo "Error: website icon directory not found: $WEBSITE_ICON_DIR"
  exit 1
fi

SOURCE_WIDTH=$(sips -g pixelWidth "$SOURCE_IMAGE" | awk '/pixelWidth/ { print $2 }')
SOURCE_HEIGHT=$(sips -g pixelHeight "$SOURCE_IMAGE" | awk '/pixelHeight/ { print $2 }')

if [[ -z "$SOURCE_WIDTH" || -z "$SOURCE_HEIGHT" ]]; then
  echo "Error: failed to read image size for $SOURCE_IMAGE"
  exit 1
fi

if [[ "$SOURCE_WIDTH" != "$SOURCE_HEIGHT" ]]; then
  echo "Error: source image must be square, got ${SOURCE_WIDTH}x${SOURCE_HEIGHT}"
  exit 1
fi

if (( SOURCE_WIDTH < 1024 )); then
  echo "Error: source image must be at least 1024x1024, got ${SOURCE_WIDTH}x${SOURCE_HEIGHT}"
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/app-icon.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

ICON_SPECS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for spec in "${ICON_SPECS[@]}"; do
  size="${spec%%:*}"
  filename="${spec#*:}"
  sips -s format png -z "$size" "$size" "$SOURCE_IMAGE" --out "$TMP_DIR/$filename" >/dev/null
done

cat > "$TMP_DIR/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

cp "$TMP_DIR/Contents.json" "$APPICON_DIR/Contents.json"

for spec in "${ICON_SPECS[@]}"; do
  filename="${spec#*:}"
  cp "$TMP_DIR/$filename" "$APPICON_DIR/$filename"
done

sips -s format png "$SOURCE_IMAGE" --out "$WEBSITE_ICON" >/dev/null

echo "Generated macOS app icons in $APPICON_DIR from $SOURCE_IMAGE"
echo "Generated website icon at $WEBSITE_ICON from $SOURCE_IMAGE"
