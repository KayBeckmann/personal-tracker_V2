# Sync: Kryptografie und Bedrohungsmodell

Stand: M3 (App 0.3.0, Server 1.0.0). Diese Datei soll eine unabhängige Prüfung möglich machen. Die Verfahren sind etabliert, die Bibliotheken auch (pointycastle in der App, `package:crypto` im Server). Eigene Kryptografie gibt es nicht. Der Code steht in `app/lib/core/sync/` und `server/lib/src/`. Die Tests liegen in `app/test/core/sync_test.dart` und `server/test/`.

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

## Was der Server sieht

- **Pro Konto:**
  - zufällige ID, Anlagezeitpunkt, Anzahl und Größen der Objekte (auf 256 Byte gerundet);
  - Zeitpunkte und Reihenfolge der Änderungen;
  - Anzahl der Geräte mit Anlage- und „zuletzt gesehen“-Zeitpunkt;
  - IP-Adressen der Anfragen.
- **Nicht:**
  - Inhalte, Titel, Beträge, Konten, Bereichsnamen und lokale IDs;
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
