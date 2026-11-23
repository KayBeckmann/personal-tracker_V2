# Personal Tracker V2 – App (Flutter, Android + Web)

Stand **M2**: Solo-Tracker, dauerhaft ohne Konto, Server oder Internet nutzbar.
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
  Die App hat **keine INTERNET-Berechtigung**.

## Datenschutz und Sicherheit

| Thema | Umsetzung |
|---|---|
| Speicher | Sembast (Android: Datei, Web: IndexedDB); jeder Datensatz einzeln AES-256-GCM-verschlüsselt, AAD = Bereich/ID |
| Schlüssel | Zufälliger Datenschlüssel (DEK) in Hüllen: Passwort (Android Argon2id 19 MiB/t=2, Web PBKDF2-SHA256 600.000 über WebCrypto) und Recovery-Schlüssel (160 Bit, Crockford-Base32) |
| Fingerabdruck | Android: DEK zusätzlich im Keystore, an starke Biometrie gebunden |
| Sperre | Beim Start, per Knopf und nach 5 Min im Hintergrund; offene Seiten werden geschlossen |
| Sicherung | `.ptbackup`: JSON-Kopf (als AAD gebunden) + AES-GCM-Inhalt mit Schlüssel aus dem Recovery-Schlüssel; Einlesen mit Vorschau, in frischer oder laufender Installation |
| Erinnerungen | Termine und Aufgaben. Android: im System geplant (30 Tage, max. 60), ohne Titel, sofern nicht eingestellt. Web: nur bei geöffneter App |
| Schema | `lib/core/speicher/schema.dart`: Version + Migrationen (1 = M1, 2 = M2 mit Aufgaben); neuere Stände werden abgelehnt, Migration in einer Transaktion |

Unverschlüsselt liegen nur Schlüsselbund, Schemaversion und Farbschema.

## Aufbau

```
lib/core/   krypto/ speicher/ modell/ kalender/ aufgaben/ finanzen/ dienste/ sitzung.dart
lib/ui/     zugang/ uebersicht/ termine/ aufgaben/ notizen/ finanzen/ einstellungen/ shell.dart thema.dart
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
