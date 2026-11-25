# Datenschutzhinweise für den gehosteten Sync – ENTWURF

> **Entwurf, nicht veröffentlichen.** Technische Grundlage für eine Datenschutzerklärung des Betreibers. Er ersetzt keine Rechtsberatung. Platzhalter in `[eckigen Klammern]` füllt der Betreiber. Rechtsgrundlagen, Fristen und Formulierungen sind juristisch zu prüfen. Stand: Server 1.5.0.

## Verantwortlicher

[Name, Anschrift, Kontakt des Betreibers] · Datenschutzkontakt: [E-Mail]

## Worum es geht

Der Dienst speichert verschlüsselte Daten der Personal-Tracker-App, damit mehrere Geräte einer Person abgleichen und Personen gezielt etwas teilen können. Die App verschlüsselt **auf dem Gerät**, bevor etwas gesendet wird (Ende-zu-Ende). Der Betreiber hat keine Schlüssel und kann Termine, Notizen, Beträge, Dateien, Dateinamen oder Gerätenamen nicht lesen.

## Welche Daten der Server verarbeitet

| Daten | Zweck | Speicherdauer |
|---|---|---|
| Verschlüsselte Inhalte (Geheimtext) mit Größe und Zeitpunkt | Speicherung und Abgleich | bis zur Löschung durch die Person oder des Kontos |
| Zufällige Konto-, Geräte- und Raum-IDs; Anzahl der Geräte; Anlage- und „zuletzt gesehen“-Zeitpunkt | Anmeldung, Geräteverwaltung | bis zur Löschung des Geräts bzw. Kontos |
| Gehashte Anmeldetoken und gehashtes Recovery-Anmeldegeheimnis | Anmeldung | wie oben |
| Für Freigaben: welches Konto in welchem Raum mit welchem Recht ist | Rechteprüfung | bis zum Entfernen bzw. Löschen |
| Gehashte Einladungscodes für die Registrierung | Zugang zu neuen Konten | [bis zum Ablauf + X Tage] |
| IP-Adresse | Begrenzung von Anmeldeversuchen (Missbrauchsschutz) | nur im Arbeitsspeicher, rund [10 Minuten]; nicht im Protokoll |
| Betriebsprotokoll: Methode, Pfad mit gekürzten IDs, Status, Dauer | Fehlersuche, Betrieb | [5 Dateien à 10 MiB, rollierend] |
| Sicherungskopien der Datenbank (nur Geheimtext) | Wiederherstellung nach Ausfall | [14 Tage, rollierend] |

**Nicht** verarbeitet: Namen, E-Mail-Adressen, Telefonnummern, Standorte, Klartext-Inhalte. Es gibt keine Tracker, Analyse- oder Werbedienste. Die Web-App lädt nichts von fremden Servern.

[Abrechnung: Welche Vertrags- und Zahlungsdaten getrennt vom Sync-Server verarbeitet werden, beim wem, wie lange (handels- und steuerrechtliche Fristen).]

## Freiwilliger öffentlicher Preiskatalog

Nur wer in der App „Eigene Preise veröffentlichen“ einschaltet **und** einen einzelnen Preis bewusst veröffentlicht, gibt diese Angaben öffentlich preis: Artikel, Packung, Kette, Filiale, Region, Preis, Tag, dazu ein Pseudonym je Konto. Diese Angaben sind **nicht** verschlüsselt. Sie werden an andere teilnehmende Instanzen weitergegeben (Föderation) und dort gespeichert. Ein Zurückziehen erreicht alle Instanzen, die sich an das Protokoll halten. Bereits abgerufene Kopien lassen sich aber nicht erzwingbar löschen. Nie öffentlich sind Position, Listen, Einkäufe und Namen.

## KI-Agenten

Wer einen eigenen KI-Agenten verbindet, tut das über ein Programm auf dem eigenen Rechner („pt-agent“). Es entschlüsselt dort. Welche Daten an den gewählten KI-Anbieter gehen, bestimmt die Person mit den Modulrechten. Der Betreiber dieses Dienstes ist an dieser Übertragung nicht beteiligt und sieht sie nicht.

## Empfänger

- Hosting-Anbieter als Auftragsverarbeiter: [Name, Ort, AVV].
- Andere Katalog-Instanzen: nur die bewusst veröffentlichten Katalogbeiträge.
- Keine Übermittlung in Drittländer [prüfen und ggf. anpassen].

## Rechte der Personen

Auskunft, Berichtigung, Löschung, Einschränkung, Datenübertragbarkeit, Widerspruch und Beschwerde bei einer Aufsichtsbehörde [zuständige Behörde]. Praktisch gilt:

- **Löschen:** In der App unter „Trennen … und Konto löschen“, sofort und vollständig. Oder auf Anfrage mit Nennung der Konto-ID (App: Geräte).
- **Export:** Die App erstellt jederzeit eine verschlüsselte Sicherung, den Vault zusätzlich als ZIP. Der Betreiber kann nur Geheimtext herausgeben.
- **Auskunft:** Der Betreiber kann zu einer Konto-ID die Metadaten aus der Tabelle oben nennen, nicht die Inhalte.

## Sicherheit

TLS beim Transport; Ende-zu-Ende-Verschlüsselung mit AES-256-GCM und Schlüsseln, die nur auf den Geräten liegen. Details und Grenzen: [SICHERHEIT.md](SICHERHEIT.md).
