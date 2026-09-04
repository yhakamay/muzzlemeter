#!/bin/sh
# Render the app icon SVGs into the asset catalogs.
#
# The SVGs in this directory are the source of truth; the PNGs under
# App/**/Assets.xcassets are generated and committed so that a checkout builds
# without extra tooling. Re-run this after editing any AppIcon*.svg.
#
# Requires rsvg-convert (`brew install librsvg`). The -b flag flattens the icon
# onto an opaque background: App Store validation rejects a 1024x1024 marketing
# icon that carries an alpha channel.
set -eu

cd "$(dirname "$0")/.."
ios="App/Muzzlemeter/Resources/Assets.xcassets/AppIcon.appiconset"
watch="App/MuzzlemeterWatch/Resources/Assets.xcassets/AppIcon.appiconset"

rsvg-convert -w 1024 -h 1024 -b '#0F1620' Design/AppIcon.svg        -o "$ios/AppIcon-1024.png"
rsvg-convert -w 1024 -h 1024 -b '#000000' Design/AppIcon-Dark.svg   -o "$ios/AppIcon-1024-dark.png"
rsvg-convert -w 1024 -h 1024 -b '#000000' Design/AppIcon-Tinted.svg -o "$ios/AppIcon-1024-tinted.png"
rsvg-convert -w 1024 -h 1024 -b '#0F1620' Design/AppIcon.svg        -o "$watch/AppIcon-1024.png"

for png in "$ios"/*.png "$watch"/*.png; do
	if sips -g hasAlpha "$png" | grep -q 'hasAlpha: yes'; then
		echo "error: $png still has an alpha channel" >&2
		exit 1
	fi
done
echo "app icons rendered"
