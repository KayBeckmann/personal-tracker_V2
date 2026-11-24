# Personal Tracker Sync (Obsidian-Plugin)

Gleicht den **ganzen Vault** Ende-zu-Ende-verschlüsselt mit einem selbst gehosteten Personal-Tracker-Server ab ([server/](../server/README.md)). Dazu gehören `.obsidian` mit Plugins und Einstellungen, Anhänge und Binärdateien. Die Tracker-App (Android, Web) zeigt die Dateien an und bearbeitet Markdown, auch ohne Obsidian. Den Vertrag teilen sich App und Plugin: [protokoll/VAULT.md](../protokoll/VAULT.md).

Voraussetzungen: Obsidian ab 1.11.4 (Desktop oder Android) und Server ab 1.1.0.

## Installation

Das Plugin ist nicht im Community-Katalog. So kommt es in den Vault:

```bash
cd obsidian
npm ci
npm run build
mkdir -p <vault>/.obsidian/plugins/personal-tracker-sync
cp main.js manifest.json styles.css <vault>/.obsidian/plugins/personal-tracker-sync/
```

Danach in Obsidian unter **Einstellungen → Externe Erweiterungen** einschalten. Auf Android das Verzeichnis mit einem Dateimanager kopieren, oder das Plugin kommt nach der Einrichtung über den Sync selbst mit.

## Einrichten

1. In der Tracker-App unter **Speicher & Sicherheit → Synchronisieren → Gerät hinzufügen** einen Kopplungscode erzeugen. Er gilt 10 Minuten und nur einmal.
2. In Obsidian unter **Einstellungen → Personal Tracker Sync** Serveradresse, Gerätenamen und Code eingeben, dann **Verbinden**.
3. Danach öffnet sich die **Vorschau**. Bis hierhin ist nichts übertragen. Sie zeigt:
   - **Hochladen:** was hochgeladen wird.
   - **Vom Server holen:** was vom Server kommt.
   - **Konfliktkopien:** gleiche Pfade mit anderem Inhalt; deine Fassung bleibt als Konfliktkopie erhalten.
   - **Gesperrt:** Dateien mit möglichen Secrets, mit Regel und Zeile, aber ohne den Wert.
   - **Zu groß:** Dateien über der Größengrenze.
   - **Nicht übertragen:** die Ausnahmen.
4. **Sicherung erstellen** legt ein ZIP unter `.ptv2-sicherung/` an. Es danach an einen zweiten Ort kopieren.
5. **Ich habe die Liste geprüft**, dann **Einrichten und abgleichen**.

Abgeglichen wird bei geöffnetem Obsidian: beim Start, 5 Sekunden nach Änderungen, alle 5 Minuten und über den Knopf oder Befehl **Jetzt abgleichen**. Die Statusleiste zeigt den Stand.

## Verhalten

- **Gleichzeitige Änderungen:** Wurde eine Datei auf zwei Geräten verschieden geändert, gilt die Fassung, die zuerst beim Server war. Die andere wird zu „Notiz (Konflikt 2026-11-24 1403 Gerät).md“ im selben Ordner. Links auf das Original bleiben gültig.
- **Umbenennen und Ändern:** Hat ein Gerät nur umbenannt und das andere nur den Inhalt geändert, gilt beides, ohne Konflikt.
- **Löschen:** Vom Server gelöschte Dateien landen im Obsidian-Papierkorb (`.trash`). Eine Änderung gewinnt gegen eine Löschung.
- **Dateien in Bearbeitung:** Ändert sich eine Datei, während der Abgleich läuft, wird sie nicht überschrieben. Sie kommt beim nächsten Durchgang dran.
- **Secrets:** Die Muster stehen in [protokoll/secret-muster.json](../protokoll/secret-muster.json). Eine Datei mit Treffer bleibt lokal, bis sie in den Einstellungen einzeln freigegeben wird. Die Freigabe gilt nur für genau diesen Inhalt.
  - **Was die Erkennung kann:** Sie arbeitet nur mit Mustern. Sie übersieht andere Formate, Binärdateien und Dateien über 10 MiB.
  - **Plugins:** Plugin-Code und Plugin-Einstellungen (`.obsidian/plugins/*/data.json`) vor dem ersten Abgleich selbst durchsehen.
- **Größe:** Standardgrenze sind 100 MiB je Datei, einstellbar. Größere Dateien bleiben lokal.
- **Ausnahmen:**
  - `.git/`, `.trash/` und `.ptv2-sicherung/`.
  - Syncthing-Verwaltung: `.stfolder`, `.stversions/`, `.stignore`.
  - `.obsidian/workspace.json` und `workspace-mobile.json`, weil sie je Gerät gelten.
- **Andere Sync-Programme:** Gleicht schon Syncthing, Obsidian Sync oder Nextcloud denselben Ordner ab, warnt die Vorschau. Zwei Programme für dieselben Dateien können sich gegenseitig Änderungen überschreiben. Für den Anfang einen eigenen Test-Vault verwenden.

## Wo was liegt

- **Token und Kontoschlüssel:** in der Schlüsselablage von Obsidian (`app.secretStorage`), nicht im Vault-Ordner.
- **Abgleichstand:** im gerätebezogenen `localStorage` des Vaults.
- **`data.json` des Plugins:** nur Serveradresse, Größengrenze und Automatik. Die Datei wird mit synchronisiert.
- **Trennen:** meldet das Gerät beim Server ab. Die Dateien bleiben unverändert.

## Entwicklung

```bash
npm run check   # TypeScript
npm test        # Protokoll-Testvektoren der App, Secret-Beispiele, Abgleich gegen den echten Server (startet `dart run` in ../server)
npm run build   # main.js
```

## Grenzen

- **Kein Hintergrund-Sync:** Auf Android gleicht das Plugin nur bei geöffnetem Obsidian ab.
- **Einstellungen anderer Geräte:** Neue Einstellungen in `.obsidian` wirken in einem laufenden Obsidian erst nach einem Neustart.
- **Leere Ordner:** werden nicht übertragen.
- **Groß- und Kleinschreibung:** Auf Dateisystemen, die sie nicht unterscheiden, können `Notiz.md` und `notiz.md` kollidieren.
