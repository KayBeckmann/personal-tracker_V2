# Personal Tracker V2 – Brainstorming

**Status:** Öffentlicher Auszug aus der laufenden Ideensammlung, keine vollständige Spezifikation und **keine Roadmap**. Die fachliche Ausarbeitung ist noch nicht abgeschlossen. [Projektübersicht](README.md)

## Web-App als regulärer Client

- Neben Android soll es eine **eigenständig nutzbare Web-App auf Flutter-Basis** geben, die dieselben berechtigten persönlichen Bereiche nutzt – nicht bloß einen HTML-Mock-up oder ein Administrationsportal.
- Nach bewusstem ersten Laden/Einrichten soll sie **auch ohne laufende Backend-Verbindung lokal nutzbar** sein. Freiwilliger Sync verwendet dieselbe eigene Backend-API wie Android: selbst gehostete Instanz oder Kays kostenpflichtig gehostete Instanz als vorgeschlagene Auswahl. Die Voreinstellung löst weder Anmeldung noch Upload aus.
- Einkaufsliste mit privaten Preisen, separat freiwilliger globaler Artikel-/Preiskatalog, berechtigte Vault-Dateiansicht/-Bearbeitung und gezielte Datei-/Ordnerfreigaben sollen auch im Web-Client nutzbar sein. Ein möglicher API-/MCP-Zugang für LLM-Agenten bleibt an die effektiven Rechte des handelnden Nutzers gebunden; die Web-App schaltet keine Datenweitergabe heimlich ein.
- **Offene Fragen vor der Umsetzung:** belastbare Offline-Speicherung im Browser, Verlust des Browser-Speichers, Backup/Export und Gerätewechsel, E2EE-Schlüsselhaltung ohne Backend-Schlüssel, sichere Web-Auslieferung/Updates, Rechte und Konflikte beim Wiederverbinden. Ein installierbarer PWA-Modus ist eine technische Option, keine zugesagte Umsetzung.
- **Zu prüfen:** Nach Einrichtung ohne Server lokal öffnen und bearbeiten; nach bewusster Verbindung Änderungen ohne stillen Datenverlust abgleichen; an einer eingehend nur lesend freigegebenen Datei auch im Web keine Schreibaktion anbieten. Android und Web getrennt testen. Die vorhandenen [Mock-ups](Mockups/) sind nur synthetische UI-Entwürfe und erfüllen dies nicht.

MVP-Grenzen, Meilensteine und Prioritäten werden erst nach gemeinsamer fachlicher Klärung festgelegt.
