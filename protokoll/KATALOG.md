# Föderierter Preiskatalog (M7)

Der Katalog ist **freiwillig und öffentlich**. Anders als alle übrigen Daten ist er nicht Ende-zu-Ende-verschlüsselt, denn andere sollen ihn lesen können. Er läuft getrennt vom privaten Sync auf demselben Server. Code: `server/lib/src/katalog.dart`, `app/lib/core/katalog/`.

## Teilnahme

- **Zwei Schalter:** In der App lassen sich „Preise anderer lesen“ und „Eigene Preise veröffentlichen“ einzeln einschalten. Beide sind standardmäßig aus.
- **Veröffentlicht wird nur je Preis und bewusst:** Beim Erfassen eines Preises die Option ankreuzen und die Vorschau des Öffentlichen bestätigen.
- **Was öffentlich wird:**
  - Artikel und Variante, optional die EAN;
  - Packungsgröße mit Einheit (Stück, g, kg, ml, l);
  - Kette, Filialname und Region (Kreis) mit ihren Schlüsseln;
  - Preis in Euro;
  - Tag der Beobachtung;
  - dazu ein **Pseudonym** je Konto (`p-…@<instanz>`).
- **Nie öffentlich:** Position, Listen, Einkäufe, Buchungen, Name, Konto-ID.

## Feste Regionen, Ketten und EAN (M10)

Damit „NWM“, „Nordwestmecklenburg“ und „Nord-West Mecklenburg“ dieselbe Region sind, gilt ab Server 1.6.0:

- **Region = Landkreis oder kreisfreie Stadt** mit dem amtlichen fünfstelligen Kreisschlüssel (`regionSchluessel`, z. B. `13074` für Nordwestmecklenburg). Die App bietet nur Einträge aus der Liste an, suchbar nach Name, Kfz-Kennzeichen, Postleitzahl und Ort; aus einer gespeicherten Position schlägt sie den Kreis vor. Daten und Quellen: [REGIONEN.md](REGIONEN.md).
- **Kette** aus einer festen Liste (`ketteSchluessel`, [ketten-de.json](ketten-de.json)). Andere Läden lassen sich privat anlegen, aber nicht veröffentlichen.
- **EAN** (`ean`, GTIN-8/12/13/14 mit Prüfziffer) ist optional. Ist sie gesetzt, gilt sie statt Artikelname und Variante als Artikel. Zwei Personen bestätigen sich also auch dann, wenn sie das Produkt verschieden nennen.
- **Eigene Beiträge** brauchen Region und Kette aus der Liste. Fehlen die Schlüssel (ältere App), leitet der Server sie aus dem Text ab, wenn das eindeutig ist, und lehnt sonst mit Hinweis ab. Gespeichert werden die festen Namen.
- **Ältere Beiträge** anderer Instanzen mit freiem Text bleiben gültig. Ist der Text eindeutig (z. B. „GVM“), zählen sie zur Region; sonst nur unter genau ihrem Text.
- **Abgleich mit freier Eingabe:** Vergleich ohne Groß-/Kleinschreibung, Umlaute ausgeschrieben, nur Buchstaben und Ziffern. Zugeordnet wird nur, was genau einen Kreis bzw. eine Kette trifft („München“ ist mehrdeutig, „Stadt München“ nicht). Testfälle für App und Server: [regionen-testfaelle.json](regionen-testfaelle.json).

## Föderation (offen)

- **Feeds:** Jede Instanz veröffentlicht unter `GET /k1/feed` nur die Beiträge ihrer eigenen Konten, fortlaufend nummeriert. Andere Instanzen holen den Feed per HTTPS ab; die abgerufene Adresse ist die Herkunft. Eine Instanz kann also keine Beiträge im Namen einer anderen ausgeben, auch kein Zurückziehen.
- **Info:** `GET /k1/info` nennt die eigene Adresse. Antwortet eine Instanz unter einer anderen Adresse, wird sie nicht übernommen.
- **Offen:** Jede Instanz darf teilnehmen. Bekannte Instanzen werden im Feed weitergereicht (`peers`), so findet sich das Netz von selbst. Startpunkte stehen in `PT_KATALOG_PEERS`.
- **Abruf:** alle `PT_KATALOG_MINUTEN` (Standard 10) und mit `pt-sync katalog abgleichen`. Das Abrufen ist idempotent; eine ausgefallene Instanz hält die anderen nicht auf.
- **Prüfung:** Ungültige Einträge werden übersprungen und gezählt, etwa mit falschen Typen, unplausiblem Preis oder Datum, Steuerzeichen oder übergroßen Feldern.
- **Ohne öffentliche Adresse** (`PT_OEFFENTLICHE_URL`) bleibt der Katalog auf der eigenen Instanz.

## Bestätigung

- **Erste Stimme:** Wer einen Preis vorschlägt, zählt als erste Stimme. Der Preis ist **unbestätigt**, bis eine andere Identität ihn bestätigt.
- **Bestätigen** kann man auf zwei Wegen:
  - ausdrücklich („Habe ich auch so gesehen“);
  - mit einem eigenen, gleichen Preis für dieselbe Packung in derselben Filiale innerhalb von 14 Tagen.
- **Zählung:** Jede Identität zählt höchstens einmal. Selbst bestätigen geht nicht.
- **In der Schätzung** zählen nur Preise, die man selbst übernommen hat („Als eigenen Preis übernehmen“). Übernehmen geht nur bei bestätigten Preisen.
- **Veraltet:** Beobachtungen, die älter als 90 Tage sind, werden als veraltet gekennzeichnet.

**Grenze der offenen Föderation:** Eine Instanz kann beliebig viele Identitäten erfinden, und eine Person kann Konten auf mehreren Instanzen haben. Eine Bestätigung beweist also nicht, dass es zwei Menschen waren. Dagegen helfen nur Sperren. Diese Entscheidung ist bewusst so getroffen (25.11.2026).

## Zurückziehen, Korrektur, Moderation

- **Zurückziehen:** Wer beigetragen hat, kann eigene Beiträge zurückziehen. Das geht als Eintrag in den eigenen Feed und gilt bei allen Instanzen.
- **Korrektur:** Ein neuer Preis ersetzt einen alten nicht, beide bleiben mit Datum sichtbar. Die Historie bleibt nachvollziehbar.
- **Konto löschen:** Das zieht alle Beiträge des Kontos zurück.
- **Betreiber:**
  - `pt-sync katalog sperren <pseudonym>`: sperrt ein Konto der eigenen Instanz und zieht seine Beiträge föderiert zurück.
  - `pt-sync katalog instanz-sperren <url>` (und `instanz-freigeben`): Eine fremde Instanz wird nicht mehr abgerufen, ihre Beiträge bleiben hier ausgeblendet.
- **Begrenzung:** Je Konto sind höchstens 300 Beiträge am Tag möglich. Der Feed ist je IP begrenzt.

## Datenschutz

Beiträge sind öffentlich und werden auf anderen Instanzen gespeichert. Ein Zurückziehen erreicht nur Instanzen, die sich an das Protokoll halten. Schon abgerufene Kopien lassen sich nicht erzwingbar löschen. Wer das nicht möchte, lässt „Veröffentlichen“ aus. Der private, verschlüsselte Sync ist davon völlig unabhängig.
