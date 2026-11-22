#!/usr/bin/env bash
# Baut die Web-App vollständig offlinefähig:
# - CanvasKit lokal statt vom CDN (--no-web-resources-cdn),
# - Schriften sind ohnehin mitgeliefert,
# - offline_sw.js mit der Liste aller Build-Dateien.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build web --release --no-web-resources-cdn "$@"
cd build/web
VERSION=$(find . -type f ! -name offline_sw.js ! -name flutter_service_worker.js -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
DATEIEN=$(find . -type f ! -name offline_sw.js ! -name flutter_service_worker.js ! -name '*.map' ! -name '*.symbols' ! -path './canvaskit/chromium/*' ! -name 'skwasm*' \
  | sed 's|^\./||' | sort | python3 -c 'import json,sys; print(json.dumps(["./"]+[l.strip() for l in sys.stdin if l.strip()]))')
sed -e "s|__VERSION__|$VERSION|" -e "s|__DATEIEN__|$DATEIEN|" ../../tool/offline_sw.vorlage.js > offline_sw.js
echo "offline_sw.js: Version $VERSION, $(echo "$DATEIEN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') Dateien"
