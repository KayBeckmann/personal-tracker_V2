# Geteilte Räume (M5): Freigaben an andere Personen

Ein **Raum** ist etwas Geteiltes: ein Vault-Ordner, ein Kalender oder eine Aufgabenliste. Er gehört einem Konto, dem Eigentümer. Andere Konten werden per **Einladungscode** Mitglied, mit `lesen` oder `schreiben`. Alles andere bleibt privat; eine Familien- oder Server-Admin-Rolle gibt keine Einsicht. Server-Endpunkte: [server/API.md](../server/API.md), Abschnitt „Geteilte Räume“.

## Schlüssel

| Schlüssel | Wer hat ihn | Wozu |
|---|---|---|
| **Raumschlüssel** (256 Bit, je Epoche) | Eigentümer und Mitglieder | verschlüsselt Inhalte des Raums (AES-256-GCM) |
| **ID-Schlüssel** des Raums (256 Bit, fest) | Eigentümer und Mitglieder | Objekt-IDs (HMAC) und Block-IDs (`HKDF(…, "ptv2-raum-block-id-v1")`) |
| **Paarschlüssel** (256 Bit, je Mitglied) | Eigentümer und dieses eine Mitglied | verpackt die Raumschlüssel für das Mitglied und seine Antwort |

Eigentümer und Mitglieder legen ihre Raumdaten als Datensatz `raeume/<raum-id>` in ihrem **eigenen** Konto ab, mit dem Kontoschlüssel verschlüsselt. So haben alle eigenen Geräte und das Obsidian-Plugin sie. Auf dem Server liegen nur verpackte Schlüssel.

## Einladung (Identitätsprüfung)

1. Der Eigentümer erzeugt einen Code: 20 Zeichen Crockford-Base32 (100 Bit), Standard 7 Tage gültig, einmalig. Daraus folgen (HKDF-SHA256):
   - der Slot `hex(HKDF(code, "ptv2-einladung-slot-v1"))`,
   - der Paket-Schlüssel `HKDF(code, "ptv2-einladung-paket-v1")`,
   - der Paarschlüssel `paar = HKDF(code, "ptv2-einladung-paar-v1")`.
2. Er legt beim Server ab:
   - **`paket`:** mit dem Paket-Schlüssel verschlüsselt, AAD `ptv2-einladung|<slot>`. Inhalt `{raum, art, name, von, idSchluessel}`.
   - **`mitgliedPaket`:** mit `paar` verschlüsselt, AAD `ptv2-raum-mitglied|<raum>`. Inhalt `{epoche, schluessel: {<epoche>: <raumschlüssel>}}`.
3. Der Eigentümer gibt den Code **persönlich** weiter (Signal, mündlich, Zettel). Die eingeladene Person gibt ihn in ihrer App ein.
4. Ihre App nimmt die Einladung an. Mit der Annahme schickt sie `antwort` = `{name}`, verschlüsselt mit `paar`, AAD `ptv2-raum-antwort|<slot>`. Zurück bekommt sie das Paket und öffnet es mit dem Code; ihre Raumschlüssel stehen im `mitgliedPaket`.
5. Der Eigentümer merkt sich Slot und Paarschlüssel jeder offenen Einladung. Er erkennt das neue Mitglied daran, dass sich dessen Antwort damit öffnen lässt.

Der Server sieht den Code nie. Er kann weder Paket noch Schlüssel lesen und keinen eigenen Schlüssel unterschieben: Ohne Code passt die Verschlüsselung nicht. Wer den Code abfängt und zuerst einlöst, wird Mitglied. Das sieht der Eigentümer in der Mitgliederliste (falscher Name) und kann das Mitglied entfernen.

## Inhalte im Raum

- **Objekte:** Objekt-ID `hex(HMAC-SHA256(idSchluessel, "<bereich>/<id>"))`, die ersten 16 Byte. Der Umschlag ist derselbe wie im Konto (`{b, i, s, d}`, auf 256 Byte aufgefüllt), verschlüsselt mit dem Raumschlüssel der aktuellen Epoche. AAD ist `ptv2-raum-objekt|<raum>|<objekt-id>`. Gespeichert wird `{"e": <epoche>, "n": …, "c": …}`.
- **Blöcke:** wie im Konto, aber AAD `ptv2-raum-block|<raum>|<block-id>` und mit vorangestellter Epoche (4 Byte, Big Endian): `epoche || nonce || Geheimtext`.
- **Raum-Info:** Objekt `raum/info`, nur vom Eigentümer geschrieben: `{name, art, von, mitglieder: [{name, recht}]}`. Mitglieder sehen so, wer dabei ist.
- **Bereiche:** `vault` (Pfad relativ zum geteilten Ordner), `termine`, `aufgaben`. Lokal bekommen Termine und Aufgaben das Feld `raum`. Vault-Dateien liegen beim Eigentümer unter dem geteilten Ordner, beim Mitglied unter einem selbst gewählten Ordner (Standard `Geteilt/<Name>`).

## Rechte

- **Server:** prüft auf jedem Pfad. Fremde bekommen `404`, Schreiben mit `lesen` ergibt `403`. Mitgliederlisten sieht nur der Eigentümer, Einladen und Ändern darf nur er.
- **Apps:** zeigen Inhalte mit Leserecht nur an. Ändert das Obsidian-Plugin eine solche Datei trotzdem, wird nichts hochgeladen. Die Änderung bleibt als private Kopie unter `Eigene Änderungen/<Raum>/…`, und die Datei bekommt wieder die geteilte Fassung.
- **Vererbung:** Eine Ordnerfreigabe gilt für alles darunter, ohne Ausnahmen. Private Dateien gehören in einen anderen Ordner. Wer etwas in einen geteilten Ordner verschiebt oder einen Termin einem geteilten Kalender zuordnet, teilt es; das Herausnehmen macht es wieder privat. In beiden Fällen wird es am alten Ort gelöscht und am neuen angelegt.

## Widerruf

1. Der Eigentümer entfernt das Mitglied beim Server. Ab sofort liefert der Server ihm nichts mehr.
2. Er erzeugt einen neuen Raumschlüssel (nächste Epoche) und verteilt ihn über die Paarschlüssel an die verbliebenen Mitglieder. Alles Neue wird damit verschlüsselt.
3. Was das entfernte Mitglied schon hatte, bleibt auf seinen Geräten. Das lässt sich nicht rückwirkend löschen.
4. Vorhandene Inhalte werden nicht neu verschlüsselt. Das entfernte Mitglied kennt sie ohnehin schon, und ohne Zugang zum Server bekommt es auch keine neuen Fassungen.

## Grenzen

- **Ein Mitglied mit Leserecht und der Server zusammen** könnten Inhalte unterschieben: Das Mitglied hat den Raumschlüssel, Objekte sind nicht einzeln signiert. Der Server allein kann das nicht.
- **Metadaten beim Server:** welche Konten in welchem Raum sind, mit welchem Recht, sowie Zeitpunkte und Größen.
- **Einladen:** Nur der Eigentümer lädt ein. Weitergeben kann ein Mitglied nur, was es selbst lesen kann.
