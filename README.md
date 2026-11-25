# Personal Tracker V2

**Status: Meilensteine M1–M8 umgesetzt – Solo-Tracker für Android und Web, ohne Konto und Server nutzbar, auf Wunsch mit Ende-zu-Ende-verschlüsseltem Sync über einen selbst gehosteten Server, inklusive des ganzen Obsidian-Vaults und gezielter Freigaben an andere Personen; dazu Einkaufslisten mit Filialpreisen, ein freiwilliger, föderierter Preiskatalog und ein eng begrenzter Zugang für den eigenen KI-Agenten.** Termine, Aufgaben, Markdown-Notizen und Haushaltsbuch, lokal verschlüsselt, mit Sicherung und Wiederherstellung. Code: [app/](app/README.md), [server/](server/README.md) [obsidian/](obsidian/README.md) (Plugin) und [agent/](agent/README.md) (MCP-Brücke). Ein gehostetes Angebot gibt es noch nicht (M9). Ideen und offene Fragen: [Brainstorming](Brainstorming.md).

## Produktidee

Geplant sind eine **Android-App und eine eigenständig nutzbare Web-App auf Flutter-Basis**. Die Web-App ist als regulärer Client für Aufgaben, Einkauf, Vault-Dateien und weitere berechtigte persönliche Bereiche gedacht – nicht nur als Browser-Vorschau oder Adminseite. Beide Clients sollen nach Einrichtung auch ohne Konto und laufenden Server lokal nutzbar bleiben; für Web sind dafür Browser-Speicherung, Backup/Export und Schlüsselhaltung noch zu klären und zu testen. Ein optionaler Sync soll über dasselbe eigene Backend-Protokoll entweder auf einer selbst gehosteten Instanz oder auf einem kostenpflichtig gehosteten Angebot möglich sein. Die voreingestellte Serveroption darf keinen automatischen Upload auslösen. Der Web-App-Baustein steht im [Brainstorming](Brainstorming.md); M1 ist umgesetzt (siehe unten).

Weitere besprochene Anforderungen sind gezielte private Datei- und Ordnerfreigaben, ein optionaler Abgleich des gesamten Obsidian-Vaults mit Anzeige und berechtigter Bearbeitung in der App, Einkaufslisten mit filial- und regionsbezogenen Preisen sowie eine **separat wählbare** Teilnahme an einem globalen Artikel- und Preiskatalog. Ein konfigurierbarer, auf Nutzerrechte begrenzter API-/MCP-Zugang für LLM-Agenten ist ebenfalls geplant. Datenschutz, Verschlüsselung, Konflikte und konkrete Umsetzung sind noch zu entwerfen; nichts davon ist durch die Mock-ups implementiert.

## Stand M1 (umgesetzt, Abnahme auf Geräten offen)

- Termine mit Monatskalender, Suche, Wiederholung (täglich/wöchentlich/monatlich/jährlich, Intervall, Ende, einzelne Vorkommen löschen) und Erinnerungen.
- Markdown-Notizen mit Vorschau und Suche.
- Haushaltsbuch: Konten (Bargeld, Bank, Depot, Sonstiges), Buchungen gebucht/geplant, Umbuchungen als verknüpfte Gegenbuchungen, monatlich wiederkehrende Posten, optionaler Ausgabenrahmen, Monatsvorschau gebucht/geplant/geschätzt.
- Lokale Verschlüsselung mit Passwort, Recovery-Schlüssel und (Android) Fingerabdruck; verschlüsselte Sicherung und Wiederherstellung in frischer Installation.
- Web-App offlinefähig nach dem ersten Laden; keine Anfragen an fremde Server.

## Stand M2 (umgesetzt, Abnahme auf Geräten offen)

- Aufgaben mit Fälligkeit (oder ohne Datum), drei Wichtigkeitsstufen, optionaler Erinnerungs-Uhrzeit und Wiederholung nach dem Abhaken (verpasste Runden werden nicht nachgeholt; monatlich am 31. fällt auf den Monatsletzten).
- Aufgabenliste nach Überfällig, Heute, Nächste 7 Tage, Später, Ohne Datum; Suche; Erledigte einblendbar und wieder zu öffnen; Abhaken mit Rückgängig.
- Übersicht: Überfälliges als eigener Block, „Heute“ und „Diese Woche“ zeigen je höchstens zwei Aufgaben ohne Dublette (Woche: normal/hoch in den nächsten 7 Tagen und hohe ohne Datum). Aufgaben werden nie automatisch zu Terminen.
- Datenschema 2: vorhandene M1-Daten und M1-Sicherungen werden beim Update übernommen; eine M1-App lehnt M2-Sicherungen ab, statt Aufgaben still zu verlieren.

## Stand M3 (umgesetzt, Abnahme auf Geräten offen)

- Freiwilliger Sync über einen selbst hostbaren Server ([server/](server/README.md): Dart, SQLite, Docker Compose mit Caddy). Ohne Verbindung bleibt alles wie in M1/M2, die App stellt dann keine Netzanfragen.
- Ende-zu-Ende-verschlüsselt: Die Apps verschlüsseln jeden Datensatz vor dem Upload; der Server sieht nur Geheimtext, zufällige bzw. gehashte IDs, Revisionen und Größen. Kryptografie und Grenzen: [server/SICHERHEIT.md](server/SICHERHEIT.md), Vertrag: [server/API.md](server/API.md).
- Erstes Gerät verbindet sich mit dem Recovery-Schlüssel (Vorschau, Sicherung vorher angeboten); weitere Geräte per Einmal-Kopplungscode (10 Minuten, einmalig). Bei Verlust aller Geräte holen Serveradresse und Recovery-Schlüssel alles zurück. Recovery-Schlüssel lässt sich erneuern, Geräte lassen sich entfernen, der Sync lässt sich trennen (Daten bleiben) oder samt Serverkonto löschen.
- Abgleich bei geöffneter App automatisch und per Knopf; offline Erfasstes geht beim nächsten Mal hoch. Gleichzeitige Änderungen überschreiben einander nicht: Die zweite Fassung bleibt als sichtbarer Konflikt erhalten, bis sie übernommen oder verworfen wird.
- Datenschema 3 (Konflikt-Fassungen); M1/M2-Daten und -Sicherungen werden übernommen.

## Stand M4 (umgesetzt, Abnahme auf Geräten offen)

- **Obsidian-Plugin** ([obsidian/](obsidian/README.md)) gleicht den ganzen Vault über denselben Server ab, auf Desktop und Android. Das schließt `.obsidian`, Plugins, Anhänge und Binärdateien ein.
- **Verbinden:** per Kopplungscode aus der App. Vor dem ersten Upload zeigt eine Vorschau alle Pfade, Konflikte, Ausnahmen und mögliche Secrets und bietet eine ZIP-Sicherung an.
- **Secret-Sperre:** Erkannte Secrets bleiben lokal, bis jede Datei einzeln freigegeben ist. Angezeigt werden Regel und Zeile, nie der Wert; jede Änderung wird neu geprüft. Die Erkennung arbeitet mit Mustern ([protokoll/secret-muster.json](protokoll/secret-muster.json)) und kann Secrets übersehen.
- **Abgleich:**
  - Stabile Datei-IDs unabhängig vom Pfad, byte-genaue Anhänge.
  - Verschieben auf einem Gerät und gleichzeitiges Ändern auf einem anderen ergeben beides, ohne Konflikt.
  - Verschieden geänderte Inhalte: Die zweite Fassung wird „Notiz (Konflikt 2026-11-24 1403 Handy).md“, auch beim wiederholten Konflikt ohne Überschreiben.
  - Löschungen landen in Obsidian im Papierkorb.
- **Tracker-App:**
  - Neuer Bereich „Vault“ mit Ordnern und Suche.
  - Markdown bearbeiten, ohne YAML oder `[[Wikilinks]]` umzuschreiben, und Bilder ansehen.
  - Anlegen, Umbenennen, Löschen und ZIP-Export.
- **Dateigrößen:** Große Dateien liegen in verschlüsselten Blöcken (Server 1.1.0, DB-Schema 2). Die Grenze ist einstellbar, Standard 100 MiB.
- **Gemeinsamer Vertrag:** [protokoll/VAULT.md](protokoll/VAULT.md). Testvektoren halten Dart und TypeScript gleich.

## Stand M5 (umgesetzt, Abnahme auf Geräten offen)

- **Freigaben:** Kalender, Aufgabenlisten und Vault-Ordner lassen sich gezielt an bestimmte Personen teilen, mit Lese- oder Schreibrecht. Alles ist privat, bis es bewusst geteilt wird.
- **Einladung:** per Einmal-Code, der persönlich weitergegeben wird. Der Server kann keine fremden Schlüssel unterschieben.
- **Ordnerfreigaben:** Sie gelten für alles darunter, ohne Ausnahmen. Wer etwas in einen geteilten Ordner verschiebt oder einem geteilten Kalender zuordnet, teilt es; Herausnehmen macht es wieder privat.
- **Rechte:** Der Server prüft auf jedem Pfad. Einträge mit Leserecht sind in der App gesperrt; im Obsidian-Plugin werden lokale Änderungen daran als private Kopie unter „Eigene Änderungen“ beiseitegelegt.
- **Entfernen:**
  - Das Mitglied bekommt sofort nichts mehr, und ein neuer Schlüssel gilt für alles Weitere.
  - Seine noch nicht gesendeten Änderungen bleiben ihm privat erhalten.
  - Schon Geladenes lässt sich nicht zurückholen.
- **Server 1.2.0:** DB-Schema 3. Vertrag in [server/API.md](server/API.md), Protokoll in [protokoll/RAEUME.md](protokoll/RAEUME.md).

## Stand M6 (umgesetzt, Abnahme auf Geräten offen)

- **Einkaufslisten:** Posten mit Menge und Einheit (Stück, Packung, g, kg, ml, l) und optionaler Variante. Listen lassen sich wie Kalender teilen; dann teilen sie auch Preise und Filialen.
- **Filialen:** je Kette und Standort getrennt (zwei Aldi-Filialen bleiben zwei), optional mit Region und Kartenposition. Die Position wird nur auf Knopfdruck bestimmt und verschlüsselt gespeichert; eine Karte oder einen Kartendienst gibt es nicht. „Nächste“ wählt die nächstgelegene Filiale.
- **Preise:** je Filiale mit Packungspreis, Packungsgröße, Datum und Herkunft. Die App rechnet den Grundpreis (€/kg, €/l, €/Stück).
- **Schätzung:** Die Listensumme nutzt den jüngsten Preis der gewählten Filiale, ersatzweise derselben Region (als Schätzung markiert). Ein unbekannter Preis bleibt unbekannt und zählt nicht als 0 €.
- **Einkauf abschließen:** Die abgehakten Posten ergeben einen Vorschlag; mit dem bezahlten Betrag und dem Konto entsteht genau eine Buchung im eigenen Haushaltsbuch. Gekaufte Posten verschwinden von der Liste; nichts wird doppelt gebucht. Am globalen Preiskatalog nimmt nichts automatisch teil.

## Stand M7 (umgesetzt, Abnahme offen)

- **Preiskatalog:** freiwillig, öffentlich und föderiert über teilnehmende Server, getrennt vom verschlüsselten Sync. „Lesen“ und „Veröffentlichen“ sind getrennte Schalter, beide aus.
- **Veröffentlichen:** je Preis, nach einer Vorschau. Öffentlich werden Artikel, Packung, Kette, Filiale, Region, Preis und Tag, unter einem Pseudonym. Nie Position, Listen, Einkäufe oder Name.
- **Bestätigung:** Ein neuer Preis gilt erst als bestätigt, wenn eine zweite Person ihn bestätigt, ausdrücklich oder mit demselben Preis. Bestätigte Preise lassen sich als eigene übernehmen; unbestätigte zählen nie in Schätzungen.
- **Zurückziehen und Sperren:** Zurückziehen wirkt über alle Instanzen, auch das Löschen des Kontos zieht alles zurück. Betreiber können Konten und Instanzen sperren.
- **Grenze:** Bei offener Föderation kann eine Instanz Identitäten erfinden; eine Bestätigung ist ein Hinweis, kein Beweis. Details: [protokoll/KATALOG.md](protokoll/KATALOG.md).

## Stand M8 (umgesetzt, Abnahme offen)

- **KI-Agent:** Ein eigener Agent (z. B. Claude über MCP) bekommt Zugriff über die lokale Brücke `pt-agent` ([agent/](agent/README.md)). Sie entschlüsselt auf dem eigenen Rechner; der Server sieht weiter nur Geheimtext.
- **Rechte je Modul:** In der App wählt man je Modul aus, lesen oder schreiben, dazu die Laufzeit: bis zum Widerruf oder 7, 30 oder 90 Tage. Geteilte Einträge sind für den Agenten nur lesbar. Beim Server darf das Agenten-Gerät nichts verwalten.
- **Nur Vorschläge:** Löschen und Veröffentlichen schlägt der Agent nur vor. Die App zeigt das in der Übersicht, ausgeführt wird erst nach Bestätigung.
- **Protokoll und Widerruf:** Jeder Zugriff wird ohne Inhalte protokolliert und ist in der App sichtbar. Widerrufen meldet die Brücke sofort ab.
- **Zugangsdatei:** mit Passphrase verschlüsselt; die Passphrase kann aus `pass` kommen.
- **Grenze:** Die Modulrechte setzt die Brücke durch, nicht die Kryptografie. Details: [server/SICHERHEIT.md](server/SICHERHEIT.md#ki-agenten-m8).
- **Server 1.4.0:** DB-Schema 5. App-Schema 7.

## Mock-ups

- **[Ruhiger Tagesblick](Mockups/01-ruhiger-tagesblick.html)** – helle, ruhig gegliederte Übersicht. [Desktop-Bild](Mockups/01-ruhiger-tagesblick-desktop.png) · [Mobil-Bild](Mockups/01-ruhiger-tagesblick-mobil.png)
- **[Klarer Arbeitsbereich](Mockups/02-klarer-arbeitsbereich.html)** – dunklere, dichtere und stärker listenorientierte Variante. [Desktop-Bild](Mockups/02-klarer-arbeitsbereich-desktop.png) · [Mobil-Bild](Mockups/02-klarer-arbeitsbereich-mobil.png)

Für die Interaktion die jeweilige HTML-Datei herunterladen und lokal im Browser öffnen. Die gezeigten Namen, Beträge und Freigaben sind **erfundene Beispieldaten**. Die Entwürfe haben keinen Login, keine dauerhafte Speicherung, keine echte Rechteprüfung und keine Verbindung zu Vault, Preisdatenbank oder Sync-Backend. Bitte keine privaten Daten eingeben.

## Lizenz

[MIT](LICENSE) · © 2026 Kay Beckmann
