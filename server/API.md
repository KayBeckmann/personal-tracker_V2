# Sync-Vertrag v1

Dies ist die Schnittstelle zwischen den Apps (Android, Web, später Obsidian) und dem Sync-Server. Implementiert ist sie in `lib/src/api.dart`, der Client steht in `app/lib/core/sync/sync_api.dart`. Der Server speichert ausschließlich Daten, die er nicht lesen kann. Die Verschlüsselung beschreibt [SICHERHEIT.md](SICHERHEIT.md).

## Grundregeln

- **Format:** JSON (UTF-8). Fehler haben die Form `{"fehler": "<code>", "meldung": "<Text>"}`.
- **Version:** Das Präfix `/v1` ist die API-Version. Innerhalb von v1 kommen nur Felder hinzu. Clients ignorieren unbekannte Felder. Ändert sich etwas inkompatibel, gibt es `/v2`. Ein v2-Server bedient v1 so lange weiter, bis die Apps umgestellt sind.
- **Anmeldung:** Jedes Gerät meldet sich mit `Authorization: Bearer <token>` an. Der Token hat 256 Bit Zufall. Der Server speichert davon nur den SHA-256.
- **Anmeldung ist kein Leserecht:** Ein gültiger Token liefert nur Geheimtext. Den Kontoschlüssel kennt der Server nicht.
- **Begrenzung:** Kontoanlage, Recovery-Anmeldung und das Einlösen eines Kopplungscodes sind pro IP-Adresse begrenzt (Standard: 20 in 10 Minuten).
- **Größen:** Eine Anfrage darf höchstens 8 MiB groß sein, ein Objekt höchstens 1 MiB, ein Block höchstens 1 MiB + 64 KiB. Pro Schreibvorgang gehen höchstens 200 Änderungen durch, pro Abruf kommen höchstens 500 Objekte.

| Code | HTTP | Bedeutung |
|------|------|-----------|
| `ungueltig` | 400 | Feld fehlt, hat den falschen Typ oder ein falsches Format |
| `nicht-angemeldet` | 401 | Token unbekannt, Gerät entfernt oder Konto gelöscht |
| `verboten` | 403 | Aktion für dieses Gerät nicht erlaubt |
| `nicht-gefunden` | 404 | Kein Konto zum Recovery-Geheimnis oder Kopplungscode unbekannt bzw. abgelaufen |
| `vorhanden` | 409 | Zu diesem Recovery-Schlüssel gibt es schon ein Konto |
| `zu-gross` | 413 | Anfrage oder Feld zu groß |
| `kontingent` | 413 | Speicherplatz des Kontos aufgebraucht (`PT_MAX_KONTO_MB`) |
| `zu-viele` | 429 | Zu viele Versuche oder offene Kopplungen |

## Endpunkte

### `GET /v1/info`

Liefert `{"dienst": "personal-tracker-sync", "api": 1, "version": "1.2.0", "instanz": "<hex>"}`. Die Apps prüfen damit vor dem Verbinden, ob unter der Adresse ein passender Server läuft.

### `POST /v1/konten` – Konto anlegen

```json
{"recoveryAuth": "<base64url, 32 Byte>", "recoveryHuelle": "<Geheimtext>", "schluesselPaket": "<Geheimtext>", "geraetName": "<Geheimtext>"}
```

Antwort `201`: `{"konto": "<hex>", "geraet": "<hex>", "token": "<base64url>"}`.

Zu jedem `recoveryAuth` gibt es höchstens ein Konto. Ein zweiter Versuch mit demselben Wert endet mit `409`.

### `POST /v1/anmelden/recovery` – mit dem Recovery-Schlüssel anmelden

Gedacht für den Fall, dass kein Gerät mehr da ist, oder für ein Gerät, das schon Daten hat. Der Aufruf registriert ein neues Gerät.

```json
{"recoveryAuth": "<base64url>", "geraetName": "<Geheimtext oder leer>"}
```

Antwort: `{"konto", "geraet", "token", "recoveryHuelle"}`.

### `GET /v1/konto`

Liefert:

```json
{
  "konto": "<hex>", "seq": 42, "objekte": 17, "bloecke": 3, "belegt": 123456,
  "recoveryHuelle": "…", "schluesselPaket": "…", "erstellt": "…",
  "geraet": "<eigene id>",
  "geraete": [{"id": "…", "name": "<Geheimtext>", "erstellt": "…", "zuletzt": "…"}]
}
```

### `PUT /v1/konto/recovery` – Recovery-Schlüssel ersetzen

Body: `{"recoveryAuth", "recoveryHuelle", "schluesselPaket"}`. Danach funktioniert die Anmeldung mit dem alten Schlüssel nicht mehr.

### `DELETE /v1/konto`

Löscht das Konto mit allen Objekten, Geräten und Kopplungen.

### `PUT /v1/geraete/<id>` / `DELETE /v1/geraete/<id>`

- **`PUT`:** Benennt das eigene Gerät um. Body: `{"name": "<Geheimtext>"}`.
- **`DELETE`:** Entfernt ein Gerät desselben Kontos, auch das eigene. Danach ist dessen Token ungültig.

### `POST /v1/kopplungen` – Kopplung anbieten

Body: `{"slot": "<64 hex>", "paket": "<Geheimtext>", "gueltigSekunden": 30…900}`.

Pro Konto sind höchstens 5 Kopplungen gleichzeitig offen.

### `POST /v1/kopplungen/<slot>/einloesen`

Body: `{"geraetName": "…"}`. Antwort: `{"konto", "paket", "geraet", "token"}`.

- Eine Kopplung lässt sich genau einmal einlösen.
- Eine abgelaufene oder unbekannte Kopplung liefert `404`.

### `GET /v1/objekte?seit=<seq>&max=<n>` – abholen

Antwort: `{"objekte": [{"id", "seq", "daten"}], "bis": <seq>, "mehr": <bool>}`.

- **Reihenfolge:** Die Objekte kommen aufsteigend nach `seq`.
- **`mehr`:** Ist `mehr` gesetzt, geht es mit `seit=bis` weiter.
- **`bis` ohne neue Objekte:** Dann ist `bis` der Stand des Kontos. Liegt er unter dem Stand, den der Client kennt, wurde der Server zurückgesetzt. Der Client baut ihn dann neu auf.

### `POST /v1/objekte` – senden

```json
{"aenderungen": [{"id": "<32–64 hex>", "basis": <seq>, "aenderung": "<uuid>", "daten": "<Geheimtext>"}]}
```

Antwort: `{"ergebnisse": [{"id", "status": "ok", "seq"} | {"id", "status": "konflikt", "seq", "daten"}]}`.

Alle Änderungen laufen in einer Transaktion. Je Objekt gilt:

1. **Neues Objekt:** wird geschrieben.
2. **`basis` gleich der Serverrevision:** wird geschrieben und bekommt eine neue `seq`.
3. **Gleiche `aenderung` wie die gespeicherte:** gilt als Wiederholung, etwa nach einer verlorenen Antwort. Der Server meldet `ok` mit der bisherigen `seq` und schreibt nicht doppelt.
4. **Sonst:** `konflikt` mit der Serverfassung. Der Client holt sie ab und entscheidet selbst; der Server führt nie zusammen.

Löschungen sind gewöhnliche Objekte, deren verschlüsselter Inhalt „gelöscht“ lautet. Der Server sieht keinen Unterschied zu anderen Objekten.

### Blöcke (seit Server 1.1.0)

Größere Dateien des Vault-Syncs (über 64 KiB) liegen nicht im Objekt, sondern in verschlüsselten Blöcken zu höchstens 1 MiB Klartext. Das Objekt der Datei nennt die Block-IDs; der Server weiß nicht, welcher Block zu welcher Datei gehört. Die Block-ID ist ein HMAC über den Klartext unter einem Kontoschlüssel, gleiche Blöcke werden also nur einmal gespeichert.

- **`PUT /v1/bloecke/<id>`:** Rohdaten (`application/octet-stream`). Gibt es den Block schon, bleibt er unverändert.
- **`GET /v1/bloecke/<id>`:** Rohdaten oder `404`.
- **`POST /v1/bloecke/fehlend`:** `{"ids": [...]}` (höchstens 5000) → `{"fehlend": [...]}`. Vor dem Senden eines Objekts lädt der Client fehlende Blöcke hoch.
- **`POST /v1/bloecke/aufraeumen`:** `{"behalten": [...]}` → `{"geloescht": n}`. Entfernt Blöcke des Kontos, die nicht in der Liste stehen **und** älter als 24 Stunden sind. Die Schonfrist schützt Blöcke, die ein anderes Gerät gerade hochlädt, bevor sein Objekt ankommt. Clients rufen das nur nach einem vollständigen Abgleich ohne Ausstehendes auf.

### Geteilte Räume (seit Server 1.2.0)

Ein Raum ist ein eigener Objektbereich: ein geteilter Vault-Ordner, Kalender oder eine Aufgabenliste. Er hat einen Eigentümer und Mitglieder mit `lesen` oder `schreiben`. Der Server kennt nur IDs und Rechte. Name, Art und Inhalte verschlüsseln die Clients mit dem Raumschlüssel; siehe [protokoll/RAEUME.md](../protokoll/RAEUME.md).

- **`POST /v1/raeume`** `{"id": "<32 hex>"}`: Raum anlegen. Das anlegende Konto wird Eigentümer.
- **`GET /v1/raeume`:** alle eigenen Räume und alle, in denen das Konto Mitglied ist.
  - Eigene: `{"id", "recht": "eigentuemer", "seq", "mitglieder": [{"konto", "recht", "antwort"}], "einladungen": n}`.
  - Fremde: `{"id", "recht", "seq", "paket"}`.
- **`DELETE /v1/raeume/<id>`:** Der Eigentümer löscht den Raum samt Inhalt; ein Mitglied tritt aus.
- **`POST /v1/raeume/<id>/einladungen`** `{"slot": "<64 hex>", "recht", "paket", "mitgliedPaket", "gueltigSekunden": 30…604800}`: nur Eigentümer. Höchstens 5 offene Einladungen je Raum.
- **`POST /v1/einladungen/<slot>/annehmen`** `{"antwort"}` → `{"raum", "recht", "paket"}`:
  - Genau einmal annehmbar; danach ist das Konto Mitglied mit dem Recht aus der Einladung, und sein `paket` ist das `mitgliedPaket`.
  - Fehler: `404` (unbekannt oder abgelaufen), `409` (gehört schon dazu).
  - Pro IP begrenzt.
- **`PUT /v1/raeume/<id>/mitglieder/<konto>`** `{"recht"?, "paket"?}` und **`DELETE …`:** nur Eigentümer. Entfernte Mitglieder bekommen sofort nichts mehr.
- **Inhalte:** `GET`/`POST /v1/raeume/<id>/objekte` und `…/bloecke/…` funktionieren wie die Endpunkte des Kontos.
  - Schreiben dürfen Eigentümer und Mitglieder mit `schreiben`, sonst `403`. Aufräumen der Blöcke darf nur der Eigentümer.
  - Konten ohne Zugang bekommen `404`, als gäbe es den Raum nicht.
- **Speicherplatz:** Was im Raum liegt, zählt beim Eigentümer.

## Kompatibilität und Migration

- **Datenbank:** Das Schema der Server-Datenbank steht in `PRAGMA user_version` (aktuell 3; 2 ergänzt die Blöcke, 3 die Räume). Migrationen laufen beim Start in einer Transaktion. Eine neuere Datenbank lehnt ein älterer Server ab.
- **Schemaversion der Inhalte:** Sie steht im verschlüsselten Umschlag und ist damit Sache der Apps. Eine App spielt nichts aus einer neueren Schemaversion ein und meldet dann „App aktualisieren“.
