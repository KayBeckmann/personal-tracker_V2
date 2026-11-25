# Personal Tracker V2 – App (Flutter, Android + Web)

Stand **M3**: Solo-Tracker, dauerhaft ohne Konto, Server oder Internet nutzbar;
auf Wunsch Ende-zu-Ende-verschlüsselter Sync mit dem eigenen Server
([server/](../server/README.md)).
Termine (mit Wiederholung und Erinnerung), Aufgaben (Fälligkeit, Wichtigkeit,
Wiederholung nach dem Abhaken, Erinnerung), Markdown-Notizen und Haushaltsbuch
(Konten, Buchungen, Umbuchungen, wiederkehrende Posten, Monatsvorschau).
Layout nach Mock-up „Ruhiger Tagesblick“, hell und dunkel.

## Entwickeln

```bash
cd app
flutter pub get
flutter test                      # Kern + Oberfläche (VM)
CHROME_EXECUTABLE=/usr/bin/google-chrome-stable \
  flutter test --platform chrome test/core   # Krypto als JavaScript/WebCrypto
flutter run -d chrome             # oder ein Android-Gerät
```

## Bauen

```bash
tool/web_bauen.sh                 # build/web, vollständig offlinefähig (eigener Service Worker)
flutter build apk --release --split-per-abi   # braucht android/key.properties
```

- **Web:** CanvasKit und Schriften liegen im Build (`--no-web-resources-cdn`),
  die App lädt nichts von fremden Servern. `offline_sw.js` cacht beim ersten
  Laden alle Dateien; danach startet die App auch ohne Netz. Nach einem
  Update lädt der erste Aufruf noch die alte Fassung und holt im Hintergrund
  die neue; ab dem zweiten Aufruf läuft die neue. Beim Hochladen müssen die
  Dateien ein neueres Änderungsdatum bekommen (sonst meldet ein Server mit
  `If-Modified-Since` „unverändert“ und der Browser sieht kein Update).
- **Android:** Die Release-Signatur kommt aus `android/key.properties` (git-ignoriert,
  gleiches Schema wie bei WerkkernERP). Ohne die Datei bricht der Release-Build ab.
  INTERNET-Berechtigung nur für den freiwilligen Sync; ohne Verbindung stellt
  die App keine Netzanfragen. Unverschlüsseltes HTTP ist nur zu `localhost`
  erlaubt (`res/xml/network_security_config.xml`).

## Datenschutz und Sicherheit

| Thema | Umsetzung |
|---|---|
| Speicher | Sembast (Android: Datei, Web: IndexedDB); jeder Datensatz einzeln AES-256-GCM-verschlüsselt, AAD = Bereich/ID |
| Schlüssel | Zufälliger Datenschlüssel (DEK) in Hüllen: Passwort (Android Argon2id 19 MiB/t=2, Web PBKDF2-SHA256 600.000 über WebCrypto) und Recovery-Schlüssel (160 Bit, Crockford-Base32) |
| Fingerabdruck | Android: DEK zusätzlich im Keystore, an starke Biometrie gebunden |
| Sperre | Beim Start, per Knopf und nach 5 Min im Hintergrund; offene Seiten werden geschlossen |
| Sicherung | `.ptbackup`: JSON-Kopf (als AAD gebunden) + AES-GCM-Inhalt mit Schlüssel aus dem Recovery-Schlüssel; Einlesen mit Vorschau, in frischer oder laufender Installation |
| Erinnerungen | Termine und Aufgaben. Android: im System geplant (30 Tage, max. 60), ohne Titel, sofern nicht eingestellt. Web: nur bei geöffneter App |
| Schema | `lib/core/speicher/schema.dart`: Version + Migrationen (1 = M1, 2 = M2 mit Aufgaben, 3 = M3 mit Konflikt-Fassungen, 4 = M4 mit Vault-Dateien im Sync, 5 = M5 mit Räumen, 6 = M6 mit Einkauf, 7 = M8 mit KI-Agenten); neuere Stände werden abgelehnt, Migration in einer Transaktion |
| Vault | `lib/core/vault/`: Dateien des Obsidian-Vaults aus dem Sync (Vertrag: [protokoll/VAULT.md](../protokoll/VAULT.md)); große Dateien in verschlüsselten Blöcken, erst beim Öffnen geladen und dann zwischengespeichert; Secret-Muster aus `protokoll/secret-muster.json` (Kopie in `secret_muster.g.dart`, ein Test prüft die Gleichheit) |
| Freigaben | `lib/core/raeume/`: Räume mit Raum- und ID-Schlüssel, Einladung per Einmal-Code (Paarschlüssel aus dem Code), Widerruf mit Schlüsselwechsel; der Motor gleicht jeden Raum wie ein eigenes Konto ab und zieht Einträge beim Wechsel privat ↔ geteilt um. Protokoll: [protokoll/RAEUME.md](../protokoll/RAEUME.md) |
| Einkauf | `lib/core/einkauf/schaetzung.dart`: Preis je Filiale, sonst Region (Schätzung), sonst unbekannt (nicht 0 €); Umrechnung g↔kg, ml↔l, Stück. Standort nur auf Knopfdruck (`core/dienste/standort.dart`, Android: ACCESS_COARSE/FINE_LOCATION). |
| Katalog | `lib/core/katalog/`: öffentlicher, föderierter Preiskatalog (nicht E2EE). Lesen und Beitragen getrennt, aus; Veröffentlichen je Preis mit Vorschau; Übernehmen nur bestätigter Preise. Regeln: [protokoll/KATALOG.md](../protokoll/KATALOG.md) |
| KI-Agenten | `lib/core/agent/`: Zugang für die Brücke `pt-agent` ([agent/](../agent/README.md)) mit Modulrechten und Laufzeit; Widerruf meldet das Agenten-Gerät ab; Löschen und Veröffentlichen nur als Vorschlag, den die Person ausführt; Protokoll ohne Inhalte (jüngste 500) |
| Sync | `lib/core/sync/`: Kontoschlüssel (256 Bit) verschlüsselt jeden Datensatz vor dem Upload; Objekt-IDs sind HMACs; Kopplung per Einmal-Code, Recovery über den Recovery-Schlüssel. Details: [server/SICHERHEIT.md](../server/SICHERHEIT.md) |

Unverschlüsselt liegen nur Schlüsselbund, Schemaversion und Farbschema. Der
Sync-Zustand (Verbindung, Token, Kontoschlüssel, ausstehende Änderungen) ist
ebenfalls mit dem DEK verschlüsselt.

## Aufbau

```
lib/core/   krypto/ speicher/ modell/ kalender/ aufgaben/ finanzen/ einkauf/ dienste/ sync/ vault/ raeume/ sitzung.dart
lib/ui/     zugang/ uebersicht/ termine/ aufgaben/ notizen/ finanzen/ einkauf/ einstellungen/ sync/ vault/ raeume/ shell.dart thema.dart
```

Haushaltsbuch-Vorschau (`core/finanzen/prognose.dart`): erwartet bis Monatsende =
offene geplante Ausgaben + max(0, Ø variable Ausgaben der bis zu 3 letzten
abgeschlossenen Monate − bereits gebuchte variable Ausgaben). Ohne
abgeschlossenen Monat gibt es keine Schätzung. Umbuchungen zählen nie, Einnahmen
stehen getrennt, der Ausgabenrahmen ist ein eigener Wert.

Aufgaben-Auswahl (`core/aufgaben/auswahl.dart`): Überfällig = offen und vor
heute fällig (eigener Block). Heute = bis zu zwei heute fällige, wichtigste
zuerst. Diese Woche = bis zu zwei aus „in den nächsten 7 Tagen fällig, normal
oder hoch“ plus „hoch ohne Datum“, hohe zuerst. Niedrige erscheinen nur in der
Liste; keine Aufgabe erscheint zweimal.

Sync (`core/sync/sync_motor.dart`): erst alles Neue holen und in einer
Transaktion einspielen, dann Ausstehendes senden. Bei gleichzeitiger Änderung
gilt die zuerst beim Server angekommene Fassung; die andere bleibt als
Konflikt-Fassung erhalten, bis sie übernommen oder verworfen wird. Automatisch
nur bei entsperrter App (nach dem Entsperren, 2 s nach Änderungen, alle 5 Min,
per Knopf). Tests: `test/core/sync_test.dart` mit dem echten Server im Speicher.

Vault (`core/vault/`, `ui/vault/`): Die Dateien sind ein eigener Sync-Bereich
und nicht Teil der Sicherung (das Original liegt im Obsidian-Ordner; die App
kann den Vault als ZIP exportieren). Pfad und Inhalt werden getrennt
zusammengeführt; bei gleichzeitig verschiedenem Inhalt entsteht „Name (Konflikt
JJJJ-MM-TT HHMM Gerät).ext“. Neue Secret-Muster: `protokoll/secret-muster.json`
ändern, dann die Dart-Kopie neu erzeugen:

```bash
tool/secret_muster_erzeugen.sh
```

Testvektoren für das Plugin neu schreiben: `PT_VEKTOREN=schreiben flutter test test/core/protokoll_test.dart`.
