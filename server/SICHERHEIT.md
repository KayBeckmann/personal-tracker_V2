# Sync: Kryptografie und Bedrohungsmodell

Stand: M9 (App 0.9.0, Obsidian-Plugin 0.2.2, Agenten-Brücke 0.1.0, Server 1.5.0). Diese Datei soll eine unabhängige Prüfung möglich machen. Die Verfahren sind etabliert, die Bibliotheken auch (pointycastle in der App, `package:crypto` im Server). Eigene Kryptografie gibt es nicht. Der Code steht in `app/lib/core/sync/`, `app/lib/core/vault/`, `obsidian/src/` und `server/lib/src/`. Die Tests liegen in `app/test/core/` (`sync_test.dart`, `vault_test.dart`, `protokoll_test.dart`), `obsidian/test/` und `server/test/`.

## Schlüssel

| Schlüssel | Herkunft | Wo er liegt |
|---|---|---|
| Datenschlüssel (DEK) des Geräts | 256 Bit Zufall pro Installation | lokal in Hüllen für Passwort, Recovery-Schlüssel und Fingerabdruck (M1) |
| **Kontoschlüssel** | 256 Bit Zufall, erzeugt vom ersten Gerät | lokal, verschlüsselt mit dem DEK; auf dem Server nur in Hüllen (s. u.) |
| Recovery-Schlüssel | 160 Bit Zufall, nur auf Papier | nirgends gespeichert; daraus abgeleitet (HKDF-SHA256) werden die Anmeldung und die Hülle |
| Kopplungscode | 100 Bit Zufall (20 Zeichen Base32), 10 Minuten gültig, einmalig | nur angezeigt und abgetippt |
| Gerätetoken | 256 Bit Zufall | lokal, verschlüsselt mit dem DEK; auf dem Server nur SHA-256 |

Abgeleitete Werte (HKDF-SHA256 mit eigenem `info` je Zweck):

- **Aus dem Recovery-Schlüssel:**
  - `ptv2-sync-anmeldung-v1`: Anmeldegeheimnis. Der Server speichert nur dessen SHA-256.
  - `ptv2-sync-huelle-v1`: verschlüsselt den Kontoschlüssel zur **Recovery-Hülle**.
- **Aus dem Kontoschlüssel:**
  - `ptv2-sync-objekt-id-v1`: HMAC-Schlüssel für die Objekt-IDs.
  - `ptv2-vault-block-id-v1`: HMAC-Schlüssel für die Block-IDs großer Vault-Dateien (M4).
- **Aus dem Kopplungscode:**
  - `ptv2-kopplung-slot-v1`: Slot auf dem Server.
  - `ptv2-kopplung-paket-v1`: verschlüsselt das Kopplungspaket mit Konto-ID und Kontoschlüssel.

Alle Inhalte sind mit AES-256-GCM verschlüsselt. Jede Verschlüsselung bekommt eine zufällige 96-Bit-Nonce und eine Zweckbindung über AAD:

- **Objekte:** `ptv2-sync-objekt|<objekt-id>`. Ein Geheimtext lässt sich also nicht unter eine andere ID schieben. Zusätzlich prüft die App nach dem Entschlüsseln, ob die ID zum Inhalt passt.
- **Weitere Zwecke:** Für Recovery-Hülle, Schlüsselpaket, Gerätenamen und Kopplungspaket gibt es je eine eigene Zeichenkette.

Was der Server je Objekt speichert:

- **Objekt-ID:** `HMAC-SHA256(Bereich/ID)` mit dem ID-Schlüssel, auf 128 Bit gekürzt. Der Server erfährt so weder den Bereich (Termin, Buchung …) noch die lokale ID.
- **Inhalt:** Geheimtext eines Umschlags `{Bereich, ID, Schemaversion, Daten oder gelöscht}`, auf ein Vielfaches von 256 Byte aufgefüllt.

## Abläufe

- **Erstes Gerät:**
  1. Du gibst den Recovery-Schlüssel ein. Die App prüft ihn gegen den lokalen Schlüsselbund.
  2. Sie erzeugt den Kontoschlüssel und legt das Konto an. Dabei schickt sie die Recovery-Hülle mit und ein **Schlüsselpaket**: die Recovery-Teile, mit dem Kontoschlüssel verschlüsselt.
  3. Danach lädt sie alle lokalen Datensätze hoch. Vorher bietet sie eine Sicherung an.
- **Weiteres Gerät (Kopplung):**
  1. Das verbundene Gerät erzeugt einen Code und legt das verschlüsselte Paket unter dem abgeleiteten Slot ab.
  2. Das neue Gerät löst den Slot ein, entschlüsselt das Paket mit dem Code und holt mit dem Kontoschlüssel das Schlüsselpaket.
  3. Danach gilt auf beiden Geräten derselbe Recovery-Schlüssel.
  4. Der Server kennt den Code nicht. Er kann das Paket weder lesen noch fälschen und keinen eigenen Schlüssel unterschieben. Das ist die Identitätsprüfung: Der Code läuft am Server vorbei über den Bildschirm.
- **Alle Geräte verloren:** Serveradresse und Recovery-Schlüssel genügen.
  1. Die App meldet sich mit dem Anmeldegeheimnis an.
  2. Sie öffnet die Recovery-Hülle und holt alles ab.
  3. Unabhängig davon bleibt die Sicherungsdatei aus M1 ein zweiter Weg.
- **Recovery-Schlüssel erneuern:**
  1. Neue Anmeldung, neue Hülle und neues Schlüsselpaket gehen zuerst zum Server. Erst danach wechselt die App lokal.
  2. Die anderen Geräte übernehmen den neuen Schlüssel beim nächsten Abgleich aus dem Schlüsselpaket.
- **Gerät entfernen:** Der Token wird sofort ungültig.

## Vault-Dateien (M4)

Der Vertrag steht in [protokoll/VAULT.md](../protokoll/VAULT.md); App (Dart) und Obsidian-Plugin (TypeScript, WebCrypto) setzen ihn getrennt um. Gemeinsame Testvektoren (`protokoll/testvektoren.json`) halten beide gleich.

- **Kleine Dateien:** Jede Datei ist ein gewöhnliches Sync-Objekt mit zufälliger, stabiler ID. Dateien bis 64 KiB stehen direkt darin.
- **Große Dateien:**
  - Sie liegen in Blöcken zu 1 MiB, aufgefüllt auf 4 KiB und mit AES-256-GCM unter dem Kontoschlüssel verschlüsselt. AAD ist `ptv2-vault-block|<id>`.
  - Die Block-ID ist ein HMAC über den Klartext. Der Client prüft sie nach dem Entschlüsseln und die ganze Datei gegen ihren SHA-256.
- **Was der Server zusätzlich sieht:**
  - Anzahl und Größen der Blöcke (auf 4 KiB gerundet).
  - Gleiche Blöcke: Zwei gleiche Dateien im selben Konto haben dieselben Block-IDs. Über Konten hinweg lässt sich das nicht vergleichen, weil der HMAC-Schlüssel je Konto verschieden ist.
  - Wann Blöcke hochgeladen werden.
  - Welcher Block zu welcher Datei gehört, steht nur im verschlüsselten Objekt.
- **Secret-Sperre:** Vor dem Hochladen prüfen App und Plugin Textdateien mit gemeinsamen Mustern. Treffer bleiben lokal, bis der Eigentümer genau diese Fassung freigibt. Warnungen nennen Regel und Zeile, nie den Wert.
  - Die Erkennung ist unvollständig: andere Formate, Binärdateien und Dateien über 10 MiB werden nicht geprüft.
  - Verschlüsselung auf dem Server macht ein hochgeladenes Secret nicht harmlos. Es liegt danach auf allen Geräten des Kontos.
- **Plugin-Code als Vertrauensgrenze:** Der Vault-Sync überträgt auch `.obsidian/plugins/`. Ein Gerät, das Plugin-Code ändert, ändert ihn für alle. Obsidian führt diesen Code mit vollem Zugriff auf den Vault aus, also auch auf die Schlüssel des Plugins.
- **Schlüssel im Plugin:** Token und Kontoschlüssel liegen in der Schlüsselablage von Obsidian (`app.secretStorage`), nicht im Vault-Ordner. Andere Sync-Programme (Syncthing usw.) bekommen sie also nicht mit.
- **Aufräumen:** Clients nennen dem Server alle noch benutzten Blöcke. Ein bösartiger Client des eigenen Kontos könnte so Blöcke löschen lassen. Jüngere Blöcke als 24 Stunden bleiben immer, und vor jedem Senden lädt ein Client fehlende Blöcke erneut hoch.

## Freigaben an andere Personen (M5)

Ausführlich in [protokoll/RAEUME.md](../protokoll/RAEUME.md). Kurz:

- **Räume:** Geteilt wird in Räumen (Vault-Ordner, Kalender, Aufgabenliste), jeder mit eigenem Raumschlüssel und ID-Schlüssel. Ein Raum gehört einem Konto; Mitglieder haben `lesen` oder `schreiben`. Alles Übrige bleibt im eigenen Konto unter dem Kontoschlüssel.
- **Identitätsprüfung:** Wer eingeladen wird, bekommt einen Einmal-Code (100 Bit, 7 Tage) außerhalb des Servers.
  - Aus dem Code folgen Slot, Paketschlüssel und ein Paarschlüssel zwischen Eigentümer und Person.
  - Der Server kann ohne Code weder das Paket lesen noch einen eigenen Schlüssel unterschieben.
  - Die Antwort der Person (ihr Name) ist mit dem Paarschlüssel verschlüsselt, der Eigentümer erkennt sie daran.
- **Schlüsselverteilung:** Raumschlüssel gehen nur verpackt mit dem Paarschlüssel des jeweiligen Mitglieds an den Server (`paket`). Der Server hält keine Schlüssel, die er öffnen kann.
- **Rechte:** Der Server prüft jeden Abruf und jede Änderung. Fremde Räume beantwortet er mit `404`, Schreiben mit Leserecht mit `403`. Die Apps bieten Bearbeiten mit Leserecht gar nicht an; das Plugin legt solche Änderungen als private Kopie beiseite.
- **Widerruf:** Der Server liefert sofort nichts mehr, und ein neuer Raumschlüssel (nächste Epoche) gilt für alles Weitere. Bereits Geladenes bleibt beim entfernten Mitglied; das lässt sich nicht rückwirkend ändern.
- **Zurückholen privater Einträge:** Ein Mitglied mit Schreibrecht könnte die ID eines Eintrags kennen, der früher geteilt war und jetzt wieder privat ist. Die Clients übernehmen aus einem Raum deshalb nichts, was lokal noch an einem anderen Ort liegt. Eigene Verschiebungen löschen zuerst am alten Ort und kommen danach an.
- **Secrets:** Wird eine Datei in einen geteilten Ordner verschoben, wird sie erneut geprüft. Eine Freigabe für das eigene Konto gilt nicht automatisch für einen Raum.
- **Grenzen:**
  - Inhalte sind nicht einzeln signiert. Ein Mitglied mit Schreibrecht kann im Raum alles ändern, auch die Raum-Info (Name, Mitgliederliste).
  - Ein Mitglied mit Leserecht könnte zusammen mit dem Server Inhalte unterschieben.
  - Der Server sieht, welche Konten in welchem Raum sind und mit welchem Recht.
  - Einen Eigentümerwechsel gibt es nicht. Eine Freigabe lässt sich nur beenden und neu anlegen.

## Öffentlicher Preiskatalog (M7)

Der Katalog ist die einzige Ausnahme von der Ende-zu-Ende-Verschlüsselung: Wer etwas beiträgt, veröffentlicht es bewusst. Was das genau umfasst, steht in [protokoll/KATALOG.md](../protokoll/KATALOG.md).

- **Getrennt vom Sync:** Lesen und Beitragen sind in der App getrennt einschaltbar und standardmäßig aus. Veröffentlicht wird nur je Preis nach einer Vorschau. Position, Listen, Einkäufe und Namen verlassen das Gerät nie Richtung Katalog.
- **Identität:** Der Server zeigt ein Pseudonym je Konto, nie Konto-ID oder Anzeigename. Wer sich dasselbe Pseudonym über längere Zeit ansieht, kann Gewohnheiten erkennen, etwa Filiale, Region und Zeitpunkte.
- **Herkunft:** Jede Instanz veröffentlicht nur ihre eigenen Beiträge; die Herkunft ergibt sich aus der abgerufenen HTTPS-Adresse. Zurückziehen akzeptieren Instanzen nur von der Herkunftsinstanz.
- **Missbrauch:** Bei offener Föderation kann eine Instanz beliebig viele Identitäten erfinden und damit Bestätigungen fälschen. Gegenmittel sind Konto- und Instanzsperren. Übernommen wird ein Katalogpreis nur von Hand.

## KI-Agenten (M8)

Ein KI-Agent bekommt Zugriff über die lokale Brücke `pt-agent` ([agent/](../agent/README.md)). Sie ist eine Art eigenes Gerät des Kontos.

- **Kopplung:** wie bei einem Gerät per Einmal-Code. Das Paket trägt zusätzlich Name und Modulrechte. Der Server legt das Gerät als `art = agent` an, auf Wunsch mit Ablaufdatum. Nach dem Ablauf lehnt er das Token ab. Ein Agenten-Code taugt nicht zum Koppeln eines Geräts und umgekehrt; beide Seiten melden ein falsch gekoppeltes Gerät sofort wieder ab.
- **Server-Rechte:** Ein Agenten-Gerät darf Objekte und Blöcke lesen und schreiben, aber nichts verwalten. Kopplungen, Recovery, Konto löschen, fremde Geräte, Räume, Einladungen und Katalogbeiträge ergeben `403`.
- **Modulrechte:** Die Brücke setzt sie durch. Sie bietet nur Werkzeuge freigegebener Module an, schreibt nur private Einträge und legt für Löschen und Veröffentlichen nur Vorschläge an, die die Person in der App ausführt. Kryptografisch ist das **keine** Grenze: Die Brücke hält den Kontoschlüssel, weil die Daten eines Kontos unter einem Schlüssel liegen.
- **Am Rechner:** Die Zugangsdatei (Token, Kontoschlüssel, Raumschlüssel) ist mit einer Passphrase verschlüsselt (scrypt N=2^15, AES-256-GCM). Klartext hält die Brücke nur im Arbeitsspeicher. Wer Datei und Passphrase hat, liest alles, was das Konto lesen darf.
- **Nachvollziehbarkeit:** Jeder Werkzeugaufruf erzeugt einen Protokolleintrag ohne Inhalte. Er synchronisiert verschlüsselt und ist in der App sichtbar. Eine manipulierte Brücke könnte das Protokoll auslassen; es ist ein Hilfsmittel, kein Beweis.
- **Widerruf:** Die App meldet das Agenten-Gerät ab. Was der Agent schon gelesen hat, bleibt bei ihm, bei Bedarf auch an den KI-Anbieter übertragen. Bei Verdacht zusätzlich den Recovery-Schlüssel erneuern.

## Gehosteter Betrieb (M9)

Ein Betreiber, der den Server für andere betreibt, hat dieselbe Sicht wie jeder Server (unten). Zusätzlich gilt ([BETRIEB.md](BETRIEB.md)):

- **Registrierung:** Einladungscodes haben 100 Bit Zufall und gelten einmal. Gespeichert wird nur ihr SHA-256-Hash. Ohne Code legt die App kein Konto an, sie meldet nur bestehende an.
- **Betreiber-Befehle** zeigen Konto-IDs, Größen, Gerätezahl und Zeitpunkte, nie Inhalte. Löschen geht nur für ganze Konten. Zugriff auf Daten, Schlüssel oder Passwörter gibt es nicht. Deshalb kann der Betreiber auch nicht beim Wiederherstellen helfen.
- **Kontingente** begrenzen nur Speicher. Ist es voll, lehnt der Server Schreiben ab; lokale Daten bleiben unberührt.
- **Hosting-Auswahl in der App:** Die Instanz ist beim Bauen eingetragen und beim Verbinden vorausgewählt. Hochgeladen wird erst nach „Verbinden“, „Eigener Server“ ist gleichwertig wählbar.
- **IP-Adressen** hält der Server nur für die Versuchsbegrenzung im Arbeitsspeicher, rund ein Zeitfenster lang. Sie erscheinen nicht im Betriebsprotokoll.

## Was der Server sieht

- **Pro Konto:**
  - zufällige ID, Anlagezeitpunkt, Anzahl und Größen der Objekte (auf 256 Byte gerundet) und der Vault-Blöcke (auf 4 KiB gerundet);
  - Zeitpunkte und Reihenfolge der Änderungen;
  - Anzahl der Geräte mit Anlage- und „zuletzt gesehen“-Zeitpunkt;
  - IP-Adressen der Anfragen;
  - für Freigaben: Raum-IDs, Eigentümer- und Mitgliedskonten mit Recht sowie Größe und Zeitpunkte der Inhalte.
- **Nicht:**
  - Inhalte, Titel, Beträge, Konten, Bereichsnamen und lokale IDs;
  - Dateinamen, Ordner und Dateitypen des Vaults;
  - Gerätenamen (sie sind verschlüsselt);
  - Recovery-Schlüssel, Kontoschlüssel und Kopplungscodes.

Das Betriebsprotokoll enthält nur Methode, Pfad mit gekürzten IDs, Status und Dauer.

Wer die Server-Datenbank liest, ob Admin oder Angreifer, bekommt nur Geheimtext. Die Tests prüfen das mit Klartext-Stichproben gegen einen Dump aller Tabellen.

## Grenzen (bewusst nicht abgedeckt)

- **Manipulierter Client:** E2EE schützt nicht vor einer manipulierten App. Im Web liefert der Webserver den Code aus. Wer ihn austauschen kann, bekommt die Schlüssel beim nächsten Entsperren. Deshalb sollte die Web-App von einem anderen, vertrauenswürdigen Ort kommen als die Daten, und die installierte Android-App ist die robustere Wahl.
- **Server, der zurückhält oder zurückdreht:** Ein bösartiger Server kann Objekte zurückhalten, löschen oder einen älteren Geheimtext desselben Objekts erneut ausliefern (Rollback). Verändern oder unterschieben kann er nichts. Zurückgespielte Sicherungen erkennt die App am Revisionsstand und lädt dann alles erneut hoch. Gezieltes Zurückdrehen einzelner Objekte erkennt sie nicht.
- **Entfernte Geräte:** Ein entferntes Gerät behält, was es schon hat, auch den Kontoschlüssel. Ohne Token kommt es nicht mehr an neue Daten. Ein Server, der mit ihm zusammenarbeitet, könnte ihm aber weiter Geheimtext liefern. Bei Geräteverlust also zusätzlich den Recovery-Schlüssel erneuern. Einen Wechsel des Kontoschlüssels mit Neuverschlüsselung gibt es mit M5 (Widerruf und Rotation).
- **Kopplungscode:** Wer den Code innerhalb von 10 Minuten kennt, bekommt vollen Zugriff. Er gehört nicht in Chats oder Mails.
- **Zeitstempel in den Daten:** Sie stammen von der jeweiligen Geräteuhr. Der Abgleich hängt nicht davon ab, er ordnet nach Serverrevisionen.
- **Transport:** TLS liefert ein Reverse-Proxy (Caddy). Die Apps nehmen unverschlüsseltes HTTP nur für `localhost` an.
- **Anmeldung über den Recovery-Schlüssel:** Das Anmeldegeheimnis ist 256 Bit stark (HKDF aus 160 Bit Zufall). Raten ist aussichtslos, zusätzlich ist es pro IP begrenzt.

## Konflikte und Löschungen

Es gilt immer: Nichts wird still überschrieben.

| Hier | Dort (Server) | Ergebnis |
|---|---|---|
| unverändert | geändert / gelöscht | übernommen |
| geändert | geändert, inhaltlich gleich | nichts zu tun |
| geändert | anders geändert | Serverfassung gilt, die eigene bleibt als **Konflikt-Fassung**, sichtbar in der Übersicht und synchronisiert, bis du sie übernimmst oder verwirfst; sie zählt nicht im Saldo |
| geändert | gelöscht | Änderung bleibt und wird wieder gesendet |
| gelöscht | geändert | Änderung kommt zurück |
| Konto gelöscht | Buchung offline auf dieses Konto | Konto bleibt erhalten |
| Einstellungen | geändert | Serverfassung gilt; „letzte Sicherung“ bleibt je Gerät |
