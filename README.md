# Personal Tracker V2

**Status: Meilenstein M1 umgesetzt – Solo-Tracker für Android und Web, ohne Konto und Server.** Termine, Markdown-Notizen und Haushaltsbuch, lokal verschlüsselt, mit Sicherung und Wiederherstellung. Code und Bauanleitung: [app/](app/README.md). Ein Backend, Sync, Freigaben oder Vault-Anbindung gibt es noch nicht (folgende Meilensteine).

## Produktidee

Geplant sind eine **Android-App und eine eigenständig nutzbare Web-App auf Flutter-Basis**. Die Web-App ist als regulärer Client für Aufgaben, Einkauf, Vault-Dateien und weitere berechtigte persönliche Bereiche gedacht – nicht nur als Browser-Vorschau oder Adminseite. Beide Clients sollen nach Einrichtung auch ohne Konto und laufenden Server lokal nutzbar bleiben; für Web sind dafür Browser-Speicherung, Backup/Export und Schlüsselhaltung noch zu klären und zu testen. Ein optionaler Sync soll über dasselbe eigene Backend-Protokoll entweder auf einer selbst gehosteten Instanz oder auf einem kostenpflichtig gehosteten Angebot möglich sein. Die voreingestellte Serveroption darf keinen automatischen Upload auslösen. Der Web-App-Baustein ist im [Roadmap-Arbeitsstand](Roadmap.md) festgehalten.

Weitere besprochene Anforderungen sind gezielte private Datei- und Ordnerfreigaben, ein optionaler Abgleich des gesamten Obsidian-Vaults mit Anzeige und berechtigter Bearbeitung in der App, Einkaufslisten mit filial- und regionsbezogenen Preisen sowie eine **separat wählbare** Teilnahme an einem globalen Artikel- und Preiskatalog. Ein konfigurierbarer, auf Nutzerrechte begrenzter API-/MCP-Zugang für LLM-Agenten ist ebenfalls geplant. Datenschutz, Verschlüsselung, Konflikte und konkrete Umsetzung sind noch zu entwerfen; nichts davon ist durch die Mock-ups implementiert.

## Mock-ups

- **[Ruhiger Tagesblick](Mockups/01-ruhiger-tagesblick.html)** – helle, ruhig gegliederte Übersicht. [Desktop-Bild](Mockups/01-ruhiger-tagesblick-desktop.png) · [Mobil-Bild](Mockups/01-ruhiger-tagesblick-mobil.png)
- **[Klarer Arbeitsbereich](Mockups/02-klarer-arbeitsbereich.html)** – dunklere, dichtere und stärker listenorientierte Variante. [Desktop-Bild](Mockups/02-klarer-arbeitsbereich-desktop.png) · [Mobil-Bild](Mockups/02-klarer-arbeitsbereich-mobil.png)

Für die Interaktion die jeweilige HTML-Datei herunterladen und lokal im Browser öffnen. Die gezeigten Namen, Beträge und Freigaben sind **erfundene Beispieldaten**. Die Entwürfe haben keinen Login, keine dauerhafte Speicherung, keine echte Rechteprüfung und keine Verbindung zu Vault, Preisdatenbank oder Sync-Backend. Bitte keine privaten Daten eingeben.

## Lizenz

[MIT](LICENSE) · © 2026 Kay Beckmann
