#!/usr/bin/env bash
# Erzeugt alle App-Icons aus den SVGs in assets/logo/ (braucht rsvg-convert):
# - Android: klassisches Icon, adaptives Icon (Vordergrund + Farbe) und
#   einfarbiges Themed Icon (Android 13+),
# - Web: Favicon, Icons und maskierbare Icons.
set -euo pipefail
cd "$(dirname "$0")/.."
LOGO=assets/logo
RES=android/app/src/main/res

png() { rsvg-convert -w "$2" -h "$2" "$LOGO/$1" -o "$3"; }

for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  name=${d%%:*}
  faktor=${d##*:}
  mkdir -p "$RES/mipmap-$name"
  png logo.svg "$(python3 -c "print(round(48*$faktor))")" "$RES/mipmap-$name/ic_launcher.png"
  png logo-vordergrund.svg "$(python3 -c "print(round(108*$faktor))")" "$RES/mipmap-$name/ic_launcher_foreground.png"
  png logo-monochrom.svg "$(python3 -c "print(round(108*$faktor))")" "$RES/mipmap-$name/ic_launcher_monochrome.png"
done

png logo.svg 32 web/favicon.png
png logo.svg 192 web/icons/Icon-192.png
png logo.svg 512 web/icons/Icon-512.png
png logo-quadrat.svg 192 web/icons/Icon-maskable-192.png
png logo-quadrat.svg 512 web/icons/Icon-maskable-512.png
echo "Icons erzeugt."
