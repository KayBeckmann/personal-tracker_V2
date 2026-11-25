#!/usr/bin/env bash
# Probe für Update und Rückweg (vor jedem Server-Update mit Schemawechsel):
#   betrieb/upgrade_probe.sh <pt-sync-alt> <pt-sync-neu>
# 1. Alte Version: Konto und Objekte anlegen, Sicherung ziehen.
# 2. Neue Version auf derselben Datei: migriert, Daten und Token gelten weiter.
# 3. Alte Version auf der migrierten Datei: muss sich weigern.
# 4. Rückweg: Sicherung zurück, alte Version liefert den alten Stand.
# Arbeitet in einem Wegwerf-Ordner mit synthetischen Daten.
set -euo pipefail
ALT=$(realpath "$1"); NEU=$(realpath "$2")
W=$(mktemp -d); PORT=${PT_PROBE_PORT:-18799}; URL="http://127.0.0.1:$PORT"
PID=
stopp() { [ -n "$PID" ] && kill "$PID" 2>/dev/null && wait "$PID" 2>/dev/null || true; PID=; }
trap 'stopp; rm -rf "$W"' EXIT
start() { PT_DB="$W/sync.db" PT_PORT=$PORT "$1" > "$W/log" 2>&1 & PID=$!; for _ in $(seq 50); do curl -sf "$URL/v1/info" >/dev/null && return 0; sleep 0.1; done; cat "$W/log"; return 1; }
objekt() { printf '{"aenderungen":[{"id":"%s","basis":0,"aenderung":"%s","daten":"%s"}]}' "$(head -c32 /dev/urandom | sha256sum | cut -c1-64)" "a$RANDOM$RANDOM" "$1"; }
pruefsumme() { curl -sf -H "authorization: Bearer $TOKEN" "$URL/v1/objekte?seit=0&max=500" | python3 -c 'import json,sys; print(sorted(o["daten"] for o in json.load(sys.stdin)["objekte"]))'; }

start "$ALT"; echo "1) alte Version: $(curl -sf "$URL/v1/info")"
K=$(curl -sf -X POST "$URL/v1/konten" -d '{"recoveryAuth":"'"$(head -c32 /dev/urandom | base64 | tr '+/' '-_')"'","recoveryHuelle":"H","schluesselPaket":"P","geraetName":"g"}')
TOKEN=$(echo "$K" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
for i in 1 2 3; do curl -sf -X POST -H "authorization: Bearer $TOKEN" "$URL/v1/objekte" -d "$(objekt "GEHEIMTEXT-$i")" >/dev/null; done
VORHER=$(pruefsumme); echo "   3 Objekte angelegt"
PT_DB="$W/sync.db" "$ALT" sichern "$W/vorher.db" >/dev/null; echo "   Sicherung gezogen"
stopp

start "$NEU"; echo "2) neue Version: $(curl -sf "$URL/v1/info")"
[ "$(pruefsumme)" = "$VORHER" ] || { echo "FEHLER: Daten nach Migration anders"; exit 1; }
curl -sf -X POST -H "authorization: Bearer $TOKEN" "$URL/v1/objekte" -d "$(objekt "NACH-UPDATE")" >/dev/null
echo "   Daten gleich, Token gilt, Schreiben geht"
stopp

if PT_DB="$W/sync.db" PT_PORT=$PORT timeout 5 "$ALT" > "$W/log" 2>&1; then echo "FEHLER: alte Version startet auf migrierter Datei"; exit 1; fi
echo "3) alte Version verweigert die migrierte Datei: $(grep -o 'neueren Server-Version[^)]*)' "$W/log" | head -1)"

cp "$W/vorher.db" "$W/sync.db"; rm -f "$W/sync.db-wal" "$W/sync.db-shm"
start "$ALT"
[ "$(pruefsumme)" = "$VORHER" ] || { echo "FEHLER: Rückweg liefert anderen Stand"; exit 1; }
echo "4) Rückweg: Sicherung zurück, alte Version liefert den alten Stand (ohne NACH-UPDATE)"
echo "PROBE OK"
