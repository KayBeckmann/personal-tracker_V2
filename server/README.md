# Personal-Tracker-Sync (Self-Hosting)

Optionaler Sync-Server für den Personal Tracker V2. Ohne ihn bleiben die Apps voll nutzbar.

Die Apps verschlüsseln alles, bevor es den Server erreicht. Der Server speichert nur Geheimtext und kann ihn nicht lesen. Wie das funktioniert und wo die Grenzen liegen, steht in [SICHERHEIT.md](SICHERHEIT.md). Den Vertrag zwischen App und Server beschreibt [API.md](API.md).

- Ein einzelnes Programm (Dart, AOT-kompiliert) mit einer SQLite-Datei.
- TLS übernimmt ein Reverse-Proxy. Im Beispiel ist das Caddy mit automatischem Let's-Encrypt-Zertifikat.

## Installation mit Docker Compose

Voraussetzung: ein Rechner mit Docker und eine Domain, die auf ihn zeigt. Ports 80 und 443 müssen erreichbar sein.

```bash
git clone <repo> personal-tracker_V2
cd personal-tracker_V2/server
# In Caddyfile sync.example.org durch die eigene Domain ersetzen.
nano Caddyfile
docker compose up -d --build
curl https://sync.example.org/v1/info
```

Die Antwort ist `{"dienst":"personal-tracker-sync","api":1,…}`. In der App unter **Einstellungen → Optional synchronisieren → Mit Server verbinden** die Adresse `https://sync.example.org` und den Recovery-Schlüssel eingeben.

Wer die Web-App von einer festen Adresse ausliefert, kann den CORS-Ursprung begrenzen (in `compose.yaml`, Standard `*`):

```yaml
    environment:
      PT_URSPRUNG: "https://tracker.example.org"
```

### Ohne Docker

```bash
cd server
dart pub get
dart compile exe bin/server.dart -o pt-sync
PT_DB=/var/lib/pt-sync/sync.db PT_HOST=127.0.0.1 PT_PORT=8743 ./pt-sync
```

Davor einen Reverse-Proxy mit TLS setzen. Läuft er auf derselben Maschine, zusätzlich `PT_HINTER_PROXY=1`. Benötigt wird `libsqlite3` (Debian: `libsqlite3-0`).

| Variable | Standard | Bedeutung |
|---|---|---|
| `PT_DB` | `daten/sync.db` | Pfad der SQLite-Datei |
| `PT_HOST` / `PT_PORT` | `127.0.0.1` / `8743` | Adresse |
| `PT_URSPRUNG` | `*` | erlaubter Ursprung der Web-App (CORS) |
| `PT_HINTER_PROXY` | – | `1`: Client-IP für die Versuchsbegrenzung aus `X-Forwarded-For` |
| `PT_MAX_KONTO_MB` | – (unbegrenzt) | Speicherplatz je Konto in MiB (Objekte und Dateiblöcke des Vault-Syncs) |

## Sicherung und Wiederherstellung (Server)

Die Datenbank enthält nur Geheimtext. Eine Sicherung ist deshalb unkritisch zu lagern, ersetzt aber keine Sicherungsdatei aus der App. Beide Wege sind unabhängig voneinander.

```bash
# Konsistente Kopie, auch bei laufendem Server:
docker compose exec sync pt-sync sichern /daten/sicherung-$(date +%F).db
docker compose cp sync:/daten/sicherung-$(date +%F).db .

# Wiederherstellen:
docker compose stop sync
docker compose cp sicherung-2026-11-24.db sync:/daten/sync.db
docker compose start sync
```

Nach dem Zurückspielen einer **älteren** Sicherung merken die Apps beim nächsten Abgleich, dass der Server weniger kennt. Sie laden dann ihren Stand erneut hoch. Was seitdem nur auf dem Server lag, ist verloren. Das betrifft Änderungen eines Geräts, das inzwischen auch weg ist.

## Update und Migration

- **Ablauf:** `git pull && docker compose up -d --build`.
- **Datenbank:** Das Schema wird beim Start migriert, in einer Transaktion. Vor größeren Updates eine Sicherung ziehen (siehe oben).
- **Rückweg:** Eine ältere Server-Version verweigert eine bereits migrierte Datenbank. Dann die vorherige Sicherung zurückspielen.
- **Vertrag:** Die API-Version steht im Pfad (`/v1`). Siehe [API.md](API.md), „Kompatibilität“.

## Umzug auf einen anderen Server

Der Umzug ist ohne Server-Export möglich:

1. Neuen Server aufsetzen.
2. Auf **einem** Gerät: Einstellungen → Synchronisieren → **Trennen**.
3. Mit der neuen Adresse und dem Recovery-Schlüssel wieder **verbinden**. Dadurch lädt das Gerät alles hoch.
4. Auf den anderen Geräten ebenfalls trennen und mit demselben Recovery-Schlüssel verbinden. Das Konto existiert dann schon, die Daten werden zusammengeführt, Dubletten entstehen nicht.
5. Auf dem alten Server zuletzt „Trennen … und Konto löschen“ wählen oder ihn abschalten.

Alternativ lässt sich die Datei `sync.db` 1:1 auf den neuen Server kopieren. Die Apps brauchen dann nur die neue Adresse; dafür trennen und mit dem Recovery-Schlüssel neu verbinden.

## Entwicklung

```bash
dart analyze && dart test
PT_DB=/tmp/pt-sync.db dart run bin/server.dart   # http://127.0.0.1:8743
```

Die App-Tests (`app/test/core/sync_test.dart`) binden diesen Server direkt im Speicher ein. Damit laufen echte Abgleiche zwischen mehreren Geräten, ohne Netzwerk.
