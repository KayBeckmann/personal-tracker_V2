#!/usr/bin/env bash
# Tägliche Server-Sicherung mit Prüfung und Rotation (für cron oder systemd-Timer).
#   betrieb/sichern.sh [ZIEL] [BEHALTEN]
# Beispiel (crontab): 30 3 * * * /opt/personal-tracker_V2/server/betrieb/sichern.sh /var/backups/pt-sync 14
# Die Kopien enthalten nur Geheimtext; trotzdem nicht öffentlich ablegen.
set -euo pipefail
cd "$(dirname "$0")/.."
ZIEL="${1:-./sicherungen}"
BEHALTEN="${2:-14}"
NAME="sync-$(date +%F-%H%M%S).db"
mkdir -p "$ZIEL"

docker compose exec -T sync pt-sync sichern "/daten/$NAME" >/dev/null
docker compose cp "sync:/daten/$NAME" "$ZIEL/$NAME"
docker compose exec -T sync rm -f "/daten/$NAME"

# Kopie prüfen: lässt sie sich öffnen, ist sie in sich stimmig?
docker run --rm -v "$(realpath "$ZIEL"):/pruefen:ro" \
  --entrypoint /usr/local/bin/pt-sync "$(docker compose images -q sync | head -1)" pruefen "/pruefen/$NAME"

# Alte Sicherungen entfernen (die jüngsten $BEHALTEN bleiben).
ls -1t "$ZIEL"/sync-*.db | tail -n +"$((BEHALTEN + 1))" | xargs -r rm -f
echo "Gesichert: $ZIEL/$NAME"
