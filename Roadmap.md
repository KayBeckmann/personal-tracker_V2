# Personal Tracker V2 – Roadmap (Arbeitsstand)

## M1 – Solo-Tracker, Android + Web, standalone (umgesetzt, Abnahme auf Geräten offen)

- Termine mit Monatskalender, Suche, Wiederholung (täglich/wöchentlich/monatlich/jährlich, Intervall, Ende, einzelne Vorkommen löschen) und Erinnerungen.
- Markdown-Notizen mit Vorschau und Suche.
- Haushaltsbuch: Konten (Bargeld, Bank, Depot, Sonstiges), Buchungen gebucht/geplant, Umbuchungen als verknüpfte Gegenbuchungen, monatlich wiederkehrende Posten, optionaler Ausgabenrahmen, Monatsvorschau gebucht/geplant/geschätzt.
- Lokale Verschlüsselung mit Passwort, Recovery-Schlüssel und (Android) Fingerabdruck; verschlüsselte Sicherung und Wiederherstellung in frischer Installation.
- Web-App offlinefähig nach dem ersten Laden; keine Anfragen an fremde Server.

Details: [app/README.md](app/README.md).

**Status:** Noch in der fachlichen Ausarbeitung. Diese Datei dokumentiert den ausdrücklich gewünschten Web-App-Baustein, nicht eine freigegebene Reihenfolge von Meilensteinen oder eine bereits gebaute Anwendung. [Projektübersicht](README.md)

## Web-App als regulärer Client

- Neben Android soll es eine **Web-App auf Flutter-Basis** geben, die dieselben persönlichen Funktionen und denselben fachlichen Daten- und Rechtevertrag nutzt; kein bloßer öffentlicher HTML-Mock-up oder reines Administrationsportal.
- Die Web-App soll nach bewusstem erstmaligem Laden/Einrichten **auch ohne laufende Backend-Verbindung lokal nutzbar** sein. Optionaler Sync erfolgt über dasselbe eigene Backend-Protokoll wie Android: selbst gehostete Instanz oder Kays kostenpflichtig gehostete Instanz als vorgeschlagene Auswahl. Die Voreinstellung löst weder Anmeldung noch Datenübertragung aus.
- Einkaufslisten mit privaten Preisen, der getrennte freiwillige globale Preiskatalog, berechtigte Vault-Dateiansicht/-Bearbeitung und gezielte Freigaben gehören zum geplanten Web-Client ebenso wie zur Android-App; keine automatische Veröffentlichung privater Daten. Ein optionaler API-/MCP-Zugang für LLM-Agenten bleibt an die effektiven Rechte des handelnden Nutzers gebunden.
- **Vor Umsetzung klären und testen:** belastbare Offline-Speicherung im Browser, Geräte-/Browserwechsel und Backup/Export, Verlust des Browser-Speichers, E2EE-Schlüsselhaltung ohne Backend-Schlüssel, sichere Auslieferung/Updates der Web-App, Rechte und Konflikte beim Wiederverbinden. Ein installierbarer PWA-Modus ist eine technische Option, noch keine zugesagte Umsetzung.

**Akzeptanzziel für eine spätere Umsetzung:** Web-App nach Einrichtung ohne Server öffnen und lokal bearbeiten; bei freiwilligem Sync eine gewählte Instanz verbinden, Änderungen ohne stille Datenverluste abgleichen und an nur lesend freigegebenen Dateien keine Schreibaktion zulassen. Tests müssen Android und Web getrennt prüfen. Die vorhandenen [Mock-ups](Mockups/) sind ausschließlich synthetische UI-Entwürfe und erfüllen diese Kriterien nicht.

Weitere Meilensteine, Prioritäten und MVP-Zuschnitt werden erst nach gemeinsamer fachlicher Klärung festgelegt.
