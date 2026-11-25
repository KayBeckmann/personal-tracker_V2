# Betrieb für andere (Hosted)

Diese Anleitung gilt für alle, die den Sync-Server **für andere Personen** betreiben, ob kostenpflichtig oder nicht. Für den eigenen Server reicht [README.md](README.md). Technik und Bedrohungsmodell stehen in [SICHERHEIT.md](SICHERHEIT.md).

Grundsatz: Der Betreiber hält **keine Schlüssel**. Er sieht Geheimtext, Größen, Zeitpunkte und Geräteanzahl (Liste in SICHERHEIT.md, „Was der Server sieht“). Er kann Konten sperren, löschen und begrenzen, aber nichts lesen.

## Vor dem Start (Entscheidungen, nicht technisch)

Diese Punkte entscheidet der Betreiber. Für Kays Angebot sind sie **offen**, eine Freigabe gibt es nur ausdrücklich:

- [ ] Hostingort und -anbieter (Rechenzentrum, Land), Auftragsverarbeitungsvertrag mit dem Anbieter
- [ ] Preise, Zahlungsweg, Abrechnung, Kündigung
- [ ] Nutzungsbedingungen, Impressum, Datenschutzerklärung (Entwurf: [DATENSCHUTZ-ENTWURF.md](DATENSCHUTZ-ENTWURF.md), juristisch prüfen lassen)
- [ ] Support-Kanal und Reaktionszeiten, Verfügbarkeitsziel und Alarmwege
- [ ] Kontingent je Konto, Registrierungsmodus
- [ ] Teilnahme am föderierten Preiskatalog (`PT_OEFFENTLICHE_URL`) und wer moderiert
- [ ] Löschfristen für inaktive Konten (Vorschlag unten)

## Einrichten

```bash
cd personal-tracker_V2/server
nano Caddyfile            # Domain eintragen; optional Web-App-Block
nano compose.yaml         # PT_REGISTRIERUNG, PT_MAX_KONTO_MB, PT_URSPRUNG
docker compose up -d --build
docker compose ps         # sync: healthy
curl https://sync.example.org/v1/info
```

Empfohlen für Hosted: `PT_REGISTRIERUNG: "einladung"` und ein Standard-Kontingent, z. B. `PT_MAX_KONTO_MB: "1024"`.

**App mit voreingestellter Instanz bauen:** Die Instanz erscheint beim Verbinden als erste, vorausgewählte Option mit Hinweis; „Eigener Server“ bleibt gleichwertig daneben. Es lädt nichts hoch, bevor die Person „Verbinden“ wählt.

```bash
cd app
tool/web_bauen.sh --dart-define=PT_HOSTED_URL=https://sync.example.org \
  --dart-define=PT_HOSTED_NAME="Personal-Tracker-Hosting" \
  --dart-define=PT_HOSTED_HINWEIS="kostenpflichtig, Preise und Bedingungen unter example.org"
# Android entsprechend: flutter build apk --release --split-per-abi --dart-define=…
```

## Konten

```bash
docker compose exec sync pt-sync einladung 14            # Einmal-Code für ein neues Konto, 14 Tage gültig
docker compose exec sync pt-sync konten                  # Konto-ID, Anlage, MiB, Kontingent, Geräte, letzter Kontakt
docker compose exec sync pt-sync kontingent 3f2a9c 5120  # Kontingent setzen (MiB; 0 = unbegrenzt; „standard“)
docker compose exec sync pt-sync konto-loeschen <volle-konto-id>
docker compose exec sync pt-sync status                  # Anzahl Konten, Geräte, Räume, Gesamtgröße
```

- **Einladung:** Den Code gibt man der Person nach Vertragsschluss bzw. Zahlung. Er gilt einmal. Wer schon ein Konto hat, braucht für weitere Geräte keinen Code.
- **Kontingent:** Es zählt alles, was das Konto belegt, auch eigene Freigaben. Ist es voll, lehnt der Server neue Daten mit einer Meldung ab. Die App zeigt „Speicher auf dem Server: x von y MiB“; lokal geht nichts verloren.
- **Kündigung und Export:** Die Person behält alle Daten auf ihren Geräten. Export geht in der App als verschlüsselte Sicherung, der Vault zusätzlich als ZIP. Umzug: trennen und mit eigener Adresse neu verbinden (README, „Umzug“). Danach löscht sie das Konto in der App („Trennen … und Konto löschen“) oder der Betreiber mit `konto-loeschen`.
- **Löschen** entfernt Konto, Geräte, Daten, Blöcke und eigene Räume sofort, zieht Katalogbeiträge föderiert zurück und lässt sich nicht rückgängig machen. In Sicherungen bleibt der Geheimtext bis zu deren Rotation (siehe unten).
- **Löschfrist (Vorschlag):** Konten ohne Gerätekontakt seit 12 Monaten nach Ankündigung löschen. `pt-sync konten` zeigt „zuletzt“. Wie die Ankündigung erreicht wird, bestimmt der Vertrag; der Server kennt keine E-Mail-Adressen.

## Überwachung

- **Healthcheck:** `GET /v1/gesund` (200/503), im Container `pt-sync gesund`. Docker markiert den Dienst als `unhealthy`; Caddy startet erst, wenn er gesund ist.
- **Von außen:** eine Uptime-Prüfung auf `https://sync.example.org/v1/gesund` (z. B. Uptime Kuma), Alarm an den Support-Kanal.
- **Protokolle:** Der Server schreibt nur Methode, Pfad mit gekürzten IDs, Status und Dauer. Caddy schreibt ohne `log`-Direktive keine Zugriffsprotokolle. Docker rotiert die Protokolle (10 MiB × 5).
- **Platz:** `pt-sync status` und `pt-sync konten`; den freien Platz des Volumes zusätzlich überwachen.

## Sicherung und Wiederherstellung

```bash
# täglich per cron: konsistente Kopie, Prüfung, die jüngsten 14 behalten
30 3 * * * /opt/personal-tracker_V2/server/betrieb/sichern.sh /var/backups/pt-sync 14
```

- Sicherungen enthalten nur Geheimtext. Trotzdem gehören sie auf ein getrenntes, nicht öffentliches Ziel, idealerweise zusätzlich außer Haus.
- **Wiederherstellungsprobe** mindestens monatlich: eine Sicherung in einen Wegwerf-Container einspielen, `pt-sync pruefen`, `pt-sync status`, dann `GET /v1/info`. Ablauf zum Zurückspielen: README.
- Nach dem Zurückspielen einer älteren Sicherung laden die Apps ihren Stand erneut hoch. Was nur auf dem Server lag, ist verloren.

## Updates und Rückweg

1. Sicherung ziehen (`betrieb/sichern.sh`).
2. Bei Schemawechsel vorher mit synthetischen Daten proben: `betrieb/upgrade_probe.sh <alt> <neu>` (prüft Migration, Token, Daten, Weigerung der alten Version, Rückweg).
3. `git pull && docker compose up -d --build`, dann `docker compose ps` (healthy) und `/v1/info` (Version).
4. **Rückweg:** alte Version auschecken und bauen, Sicherung aus Schritt 1 zurückspielen. Änderungen seit dem Update laden die Apps erneut hoch.

Die API-Version (`/v1`) bleibt stabil; neue Felder sind optional. Apps und Server prüfen die Version beim Verbinden.

## Vorfälle

- **Server kompromittiert:** Inhalte bleiben geschützt, solange die Clients unverändert sind. Token sind gehasht gespeichert. Trotzdem Betroffene informieren, Server neu aufsetzen und Sicherung einspielen. Den Personen empfehlen, Geräte zu prüfen und den Recovery-Schlüssel zu erneuern (App: „Neuer Recovery-Schlüssel“). Meldepflichten prüfen.
- **Web-App-Auslieferung kompromittiert:** Das ist der kritische Fall (siehe SICHERHEIT.md, „Manipulierter Client“). Ausgelieferten Code sofort ersetzen und Nutzer warnen. Die Web-App möglichst getrennt vom Sync-Server ausliefern, mit CSP (Beispiel im Caddyfile).
- **Missbrauch des Katalogs:** `pt-sync katalog sperren` / `instanz-sperren` (README).
- **Gerät einer Person verloren:** Das erledigt die Person selbst in der App (Gerät entfernen, Recovery-Schlüssel erneuern). Der Betreiber kann nicht helfen, an Daten zu kommen. Das ist gewollt.

## Was der Betreiber nicht kann

- Daten lesen, wiederherstellen oder Passwörter bzw. Recovery-Schlüssel zurücksetzen. Ohne Recovery-Schlüssel und ohne Gerät sind die Daten weg.
- Einzelne Inhalte gezielt löschen. Er kann nur ganze Konten löschen.
- Personen anhand der Daten identifizieren. Der Server kennt keine Namen oder E-Mail-Adressen, nur Zufalls-IDs. Eine Zuordnung Vertrag ↔ Konto entsteht nur, wenn die Person ihre Konto-ID nennt (App: Geräteliste bzw. Support).
