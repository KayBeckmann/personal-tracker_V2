# pt-agent – lokale MCP-Brücke (M8)

Gibt einem eigenen KI-Agenten Zugriff auf ausgewählte Bereiche des Personal Trackers, etwa Claude Code, Claude Desktop oder ein anderes MCP-fähiges Programm. Die Brücke läuft **auf deinem Rechner**, entschlüsselt dort im Arbeitsspeicher und spricht mit dem Agenten über stdio (MCP). Der Sync-Server sieht weiter nur Geheimtext.

Voraussetzungen: Node ab 20 (Tests: ab 23.6, wegen TypeScript ohne Übersetzen), Server ab 1.4.0, App ab 0.8.0.

## Einrichten

1. **In der App:** unter „Einstellungen → KI-Agenten → KI-Agent verbinden …“ einen Namen vergeben. Dann je Modul `aus`, `lesen` oder `schreiben` wählen (Termine, Aufgaben, Notizen, Haushaltsbuch, Einkauf, Vault) und die Laufzeit festlegen: bis zum Widerruf, 7, 30 oder 90 Tage. Die App zeigt einen Befehl mit Einmal-Code, der 10 Minuten gültig ist.
2. **Auf dem Rechner:**

   ```bash
   cd agent
   npm ci
   npm run build                      # erzeugt dist/pt-agent.mjs
   export PT_AGENT_PASSPHRASE_BEFEHL='pass show tracker/agent'   # oder interaktiv
   node dist/pt-agent.mjs koppeln --server https://sync.example.org --code XXXX-XXXX-XXXX-XXXX-XXXX
   ```

   Die Zugangsdatei liegt unter `~/.config/personal-tracker-agent/zugang.json` (oder `PT_AGENT_DATEI`). Sie ist mit der Passphrase verschlüsselt (scrypt + AES-GCM) und ohne sie nutzlos.
3. **Im KI-Programm** `pt-agent mcp` als MCP-Server eintragen, z. B. für Claude Code:

   ```bash
   claude mcp add personal-tracker --env PT_AGENT_PASSPHRASE_BEFEHL='pass show tracker/agent' -- node /pfad/zu/agent/dist/pt-agent.mjs mcp
   ```

Weitere Befehle: `pt-agent status` zeigt Server, Name und Rechte; `pt-agent abmelden` meldet die Brücke beim Server ab und löscht die Zugangsdatei.

## Was der Agent darf

- **Nur freigegebene Module.** Für jedes Modul gibt es Lese- und Schreibwerkzeuge (`termine_suchen`, `termin_anlegen`, `notiz_lesen`, `buchung_anlegen`, `posten_hinzufuegen`, `vault_schreiben` …). Werkzeuge ohne Recht werden gar nicht angeboten.
- **„schreiben“** heißt anlegen und ändern, und das nur bei privaten Einträgen. Geteilte Einträge (M5) sind für den Agenten nur lesbar.
- **Löschen und Veröffentlichen** (in den öffentlichen Preiskatalog) führt der Agent nie selbst aus. Er legt einen **Vorschlag** an. Die App zeigt ihn in der Übersicht, und erst dein „Löschen“ bzw. „Veröffentlichen“ führt ihn aus.
- **Vault:** Beim Schreiben prüft die Brücke auf mögliche Secrets (dieselben Muster wie App und Plugin) und schreibt dann nicht.
- **Protokoll:** Jeder Aufruf wird ohne Inhalte protokolliert (Werkzeug, Modul, Art, Anzahl, Zeit). Das Protokoll synchronisiert verschlüsselt und steht in der App unter „Protokoll“. Die App behält die jüngsten 500 Einträge.

## Widerruf und Ablauf

- **Widerrufen** in der App meldet das Agenten-Gerät beim Server ab. Danach bekommt die Brücke keinen Zugriff mehr.
- **Mit Laufzeit** lehnt der Server das Token nach Ablauf selbst ab.
- **Rechte:** Das Agenten-Gerät darf beim Server nichts verwalten, also keine Geräte, Kopplungen, Freigaben, Recovery, Katalogbeiträge und kein Konto-Löschen.

## Grenze

Die Brücke hält den **Kontoschlüssel**. Die Modulrechte setzt sie selbst durch, nicht die Kryptografie. Wer den Rechner mit Zugangsdatei *und* Passphrase übernimmt, kann alle Daten des Kontos lesen, die der Server liefert. Deshalb gilt:

- die Passphrase aus `pass` oder KeePassXC holen, nicht in Shell-Dateien schreiben;
- Laufzeiten nutzen;
- bei Verdacht widerrufen und den Recovery-Schlüssel erneuern.

Details: [server/SICHERHEIT.md](../server/SICHERHEIT.md#ki-agenten-m8).

## Entwicklung

```bash
npm test         # node --test, u. a. ein MCP-Client gegen dist/pt-agent.mjs
npm run check    # tsc
```

Die Kryptografie teilt sich die Brücke mit dem Obsidian-Plugin (`../obsidian/src/`). Die Testvektoren in `protokoll/testvektoren.json` halten beide mit der App gleich.
