# Regionen und Ketten (M10)

Feste Listen für den Preiskatalog, damit gleiche Regionen und Ketten gleich heißen. Regeln: [KATALOG.md](KATALOG.md#feste-regionen-ketten-und-ean-m10).

## Dateien

| Datei | Inhalt |
|---|---|
| `regionen-de.json` | 401 Kreise (Schlüssel `s`, Name `n`, Art `a`, Land `l`, Kfz-Kennzeichen `k`), Postleitzahlen → Kreise (`plz`), Orte mit Mittelpunkt (`orte`: Name, Breite, Länge, Kreis) |
| `ketten-de.json` | Ketten mit festem Schlüssel und weiteren Schreibweisen; von Hand gepflegt |
| `regionen-testfaelle.json` | freie Eingaben und erwartete Zuordnung, geprüft in App und Server |
| `regionen/erzeugen.py` | baut `regionen-de.json` aus den Rohdaten |
| `regionen/kopieren.py` | kopiert nach `app/assets/` und erzeugt `server/lib/src/regionen.g.dart` |

Ein Kreis kann mehrere Kfz-Kennzeichen haben (Nordwestmecklenburg: NWM, GVM, GDB, WIS, HWI), ein Kennzeichen mehrere Kreise (M: Stadt und Landkreis München) und eine Postleitzahl mehrere Kreise. Die Suche zeigt dann alle Treffer zur Auswahl; die automatische Zuordnung freier Texte nimmt nur eindeutige.

## Quellen und Lizenzen

- **Kreise und Gemeinden** (Schlüssel, Namen, Art, Mittelpunktkoordinaten): © Statistisches Bundesamt (Destatis), Gemeindeverzeichnis GV-ISys, Gebietsstand 30.09.2026, [Datenlizenz Deutschland – Namensnennung – 2.0](https://www.govdata.de/dl-de/by-2-0).
- **Postleitzahlen je Kreis:** [GeoNames](https://www.geonames.org), CC BY 4.0.
- **Kfz-Unterscheidungszeichen je Kreis:** aus der Wikipedia-Liste „Liste der Kfz-Kennzeichen in Deutschland“ übernommen (nur die Zuordnung Kürzel → Kreis). Sonderkennzeichen von Behörden und Bundeswehr sind nicht enthalten.

Die Namensnennung steht auch in der App, unten in der Regionsauswahl einer Filiale.

## Aktualisieren

Bei Gebietsreformen oder neuen Kennzeichen:

```bash
cd personal-tracker_V2
R=$(mktemp -d)
curl -L -o $R/gv.xlsx "https://www.destatis.de/DE/Themen/Laender-Regionen/Regionales/Gemeindeverzeichnis/Administrativ/Archiv/GVAuszugQ/AuszugGV3QAktuell.xlsx?__blob=publicationFile"
curl -L -o $R/kfz.json "https://de.wikipedia.org/w/api.php?action=parse&page=Liste_der_Kfz-Kennzeichen_in_Deutschland&prop=wikitext&format=json&formatversion=2"
curl -L -o $R/DE.zip https://download.geonames.org/export/zip/DE.zip && unzip -o $R/DE.zip -d $R
python3 -I protokoll/regionen/erzeugen.py $R/gv.xlsx $R/kfz.json $R/DE.txt
python3 -I protokoll/regionen/kopieren.py
```

`erzeugen.py` meldet Kennzeichen ohne passenden Kreis und Kreise ohne Kennzeichen. Erwartet sind nur Behörden- und Sonderkennzeichen ohne Kreis (z. B. BP, THW, Y). Schlüssel verschwinden nur bei Gebietsreformen; ältere Beiträge mit einem alten Schlüssel weist der Server dann ab, die App fragt die Region neu ab.
