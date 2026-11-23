# Personal Tracker V2

**Status: Meilensteine M1 und M2 umgesetzt – Solo-Tracker für Android und Web, ohne Konto und Server.** Termine, Aufgaben, Markdown-Notizen und Haushaltsbuch, lokal verschlüsselt, mit Sicherung und Wiederherstellung. Code und Bauanleitung: [app/](app/README.md). Ein Backend, Sync, Freigaben oder Vault-Anbindung gibt es noch nicht (folgende Meilensteine). Ideen und offene Fragen: [Brainstorming](Brainstorming.md).

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

## Mock-ups

- **[Ruhiger Tagesblick](Mockups/01-ruhiger-tagesblick.html)** – helle, ruhig gegliederte Übersicht. [Desktop-Bild](Mockups/01-ruhiger-tagesblick-desktop.png) · [Mobil-Bild](Mockups/01-ruhiger-tagesblick-mobil.png)
- **[Klarer Arbeitsbereich](Mockups/02-klarer-arbeitsbereich.html)** – dunklere, dichtere und stärker listenorientierte Variante. [Desktop-Bild](Mockups/02-klarer-arbeitsbereich-desktop.png) · [Mobil-Bild](Mockups/02-klarer-arbeitsbereich-mobil.png)

Für die Interaktion die jeweilige HTML-Datei herunterladen und lokal im Browser öffnen. Die gezeigten Namen, Beträge und Freigaben sind **erfundene Beispieldaten**. Die Entwürfe haben keinen Login, keine dauerhafte Speicherung, keine echte Rechteprüfung und keine Verbindung zu Vault, Preisdatenbank oder Sync-Backend. Bitte keine privaten Daten eingeben.

## Lizenz

[MIT](LICENSE) · © 2026 Kay Beckmann
