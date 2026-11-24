#!/bin/bash
# Renders the light look of WatchpostApp/Assets.xcassets/AppIcon.icon with Apple's ictool and
# writes the opaque 1024x1024 AppIcon.png that sits beside it in AppIcon.appiconset.
#   Tools/MakeFlatIcon/make-flat-icon.sh            write the appiconset
#   Tools/MakeFlatIcon/make-flat-icon.sh --check    render all seven looks into a temp folder
# ictool fails on paths that contain spaces, so the package is copied to a space-free temp folder first.
set -euo pipefail
cd "$(dirname "$0")/../.."
ICON=WatchpostApp/Assets.xcassets/AppIcon.icon
SET=WatchpostApp/Assets.xcassets/AppIcon.appiconset
ICT="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
WORK=$(mktemp -d /tmp/wp-icon.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cp -R "$ICON" "$WORK/"
render() { "$ICT" "$WORK/AppIcon.icon" --export-image --output-file "$WORK/$1.png" --platform iOS \
  --rendition "$2" --width "$3" --height "$3" --scale "$4" >/dev/null; }
# The fill is read from icon.json so the flat corners match the light background.
FILL=$(python3 -c '
import json, re
doc = json.load(open("'"$ICON"'/icon.json"))
m = re.match(r"srgb:([0-9.]+),([0-9.]+),([0-9.]+)", doc["fill"]["solid"])
print(" ".join(str(round(float(v) * 255)) for v in m.groups()))')
read -r R G B <<<"$FILL"
if [ "${1:-}" = "--check" ]; then
  for LOOK in Default Dark TintedLight TintedDark ClearLight ClearDark; do render "$LOOK" "$LOOK" 512 2; done
  OUT="${ICON_CHECK_DIR:-/tmp/wp-icon-renders}"; mkdir -p "$OUT"; cp "$WORK"/*.png "$OUT/"
  echo "rendered to $OUT"; exit 0
fi
render Flat Default 1024 1
mkdir -p "$SET"
xcrun swiftc -O -o "$WORK/flatten" Tools/MakeFlatIcon/flatten.swift
# flatten takes 0...1 components
"$WORK/flatten" "$WORK/Flat.png" "$WORK/AppIcon.png" \
  "$(python3 -c "print($R/255)")" "$(python3 -c "print($G/255)")" "$(python3 -c "print($B/255)")"
mv "$WORK/AppIcon.png" "$SET/AppIcon.png"
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
sips -g pixelWidth -g pixelHeight -g hasAlpha "$SET/AppIcon.png" | tail -3
