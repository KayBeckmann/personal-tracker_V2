# Vault-Sync: gemeinsamer Vertrag von App und Obsidian-Plugin

Stand: M4 (App 0.4.0, Plugin 0.1.0, Server 1.1.0). Grundlage ist der Sync-Vertrag v1 ([server/API.md](../server/API.md)) mit der Kryptografie aus [server/SICHERHEIT.md](../server/SICHERHEIT.md). Hier steht nur, was für Vault-Dateien dazukommt. Implementiert ist es zweimal: in der App (`app/lib/core/vault/`, `app/lib/core/sync/sync_motor.dart`) und im Plugin (`obsidian/src/`). Die gemeinsamen Testvektoren in diesem Ordner halten beide gleich.

## Objekt einer Datei

Jede Datei ist ein Sync-Objekt im Bereich `vault`. Die ID ist eine zufällige UUID und bleibt beim Umbenennen und Verschieben gleich. Im Umschlag (`{"b": "vault", "i": <id>, "s": 4, "d": …}`) steht:

```json
{
  "id": "<uuid>",
  "pfad": "Ordner/Notiz.md",
  "groesse": 1234,
  "sha256": "<hex des Inhalts>",
  "inhalt": "<base64>",
  "bloecke": [{"id": "<32 hex>", "groesse": 1048576}],
  "geaendert": "2026-11-24T13:03:00.000Z"
}
```

- **Pfad:** relativ zur Vault-Wurzel, mit `/`. Abgelehnt werden absolute Pfade, `..`, `.`, leere Teile, Laufwerksbuchstaben und Steuerzeichen.
- **Inhalt:** Bis 64 KiB steht er base64-kodiert in `inhalt`. Größere Dateien stehen in `bloecke`, dann fehlt `inhalt`.
- **Löschen:** Wie bei allen Objekten ist der Umschlag `d: null`.

## Blöcke

- **Aufteilung:** Der Inhalt wird in Stücke zu 1 MiB geteilt, das letzte ist kürzer.
- **Block-ID:** `hex(HMAC-SHA256(k, stück))`, die ersten 16 Byte. `k = HKDF-SHA256(Kontoschlüssel, info "ptv2-vault-block-id-v1")`.
- **Verschlüsselung:** Das Stück wird mit Nullbytes auf ein Vielfaches von 4096 aufgefüllt und mit AES-256-GCM unter dem Kontoschlüssel verschlüsselt. AAD ist `ptv2-vault-block|<id>`. Gespeichert wird `nonce (12 Byte) || Geheimtext mit Tag`.
- **Prüfung beim Lesen:** entschlüsseln, auf `groesse` kürzen und die Block-ID neu berechnen. Die Datei als Ganzes wird gegen `sha256` geprüft.
- **Hochladen:** Vor dem Senden eines Objekts fragt der Client `POST /v1/bloecke/fehlend` und lädt fehlende Blöcke hoch.
- **Aufräumen:** höchstens einmal am Tag, und nur nach einem Abgleich, bei dem sich alles entschlüsseln ließ. Der Client nennt alle Block-IDs seiner Dateien, auch der noch nicht gesendeten. Der Server löscht nur Blöcke, die älter als 24 Stunden sind.

## Zusammenführen

Jeder Client merkt sich je Datei Pfad und Hash vom letzten Abgleich (die Basis).

| hier | dort (Server) | Ergebnis |
|---|---|---|
| unverändert | geändert, verschoben oder gelöscht | übernommen |
| nur verschoben | nur Inhalt geändert (oder umgekehrt) | beides gilt, ohne Konflikt |
| beide verschoben | – | Pfad vom Server |
| Inhalt geändert | Inhalt anders geändert | Serverfassung gilt; die eigene wird als neue Datei **„Name (Konflikt JJJJ-MM-TT HHMM Gerät).ext“** im selben Ordner angelegt, bei Namensgleichheit mit „ 2“, „ 3“ … |
| geändert | gelöscht | Änderung bleibt und wird wieder gesendet |
| gelöscht | geändert | Datei kommt zurück |
| neue Datei | Datei am selben Pfad | gleicher Inhalt: eine Datei mit der ID vom Server; anderer Inhalt: die hier neue Datei weicht auf einen Konfliktnamen aus. Liegen schon zwei Dateien mit gleichem Pfad beim Server, weicht die mit der größeren ID, auf allen Geräten gleich |

Links auf die Originaldatei bleiben gültig, weil die Serverfassung den Namen behält. Das Plugin verschiebt lokal gelöschte oder vom Server gelöschte Dateien in den Obsidian-Papierkorb (`.trash`), statt sie zu entfernen.

## Was nicht synchronisiert wird

Diese Ausnahmen zeigt das Plugin in der Vorschau an:

- **Syncthing:** `.stfolder`, `.stversions/`, `.stignore`.
- **Git:** `.git/`.
- **Papierkorb:** `.trash/`.
- **Pro Gerät:** `.obsidian/workspace.json`, `.obsidian/workspace-mobile.json`.
- **Sicherungen des Plugins:** `.ptv2-sicherung/`.

## Vor dem Hochladen

- **Größe:** Dateien über der eingestellten Grenze bleiben lokal. Standard sind 100 MiB, App und Plugin haben je eine eigene Einstellung.
- **Secrets:** Textdateien werden mit den Mustern aus `secret-muster.json` geprüft. Bei einem Treffer bleibt die Datei lokal, bis sie einzeln freigegeben wird. Die Freigabe gilt nur für genau diesen Inhalt (Hash); jede Änderung wird neu geprüft.
  - Angezeigt werden nur Regelname und Zeile, nie der Wert.
  - Binärdateien und Dateien über 10 MiB lassen sich nicht prüfen und werden als „nicht geprüft“ gezählt.
  - Ein reines Umbenennen prüft nicht erneut, weil der Inhalt schon beim Server liegt.
