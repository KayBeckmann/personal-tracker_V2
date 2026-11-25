#!/usr/bin/env python3
"""Erzeugt protokoll/regionen-de.json aus offenen Quellen (M10).

Aufruf (Rohdaten vorher herunterladen, siehe protokoll/REGIONEN.md):

    python3 -I protokoll/regionen/erzeugen.py <gv.xlsx> <kfz-wikitext.json> <geonames-DE.txt>

Quellen:
- Kreise und Gemeinden (Schlüssel, Namen, Mittelpunkte): Statistisches
  Bundesamt, Gemeindeverzeichnis GV-ISys, dl-de/by-2-0.
- Postleitzahlen je Kreis: GeoNames, CC BY 4.0.
- Kfz-Unterscheidungszeichen je Kreis: Wikipedia, „Liste der
  Kfz-Kennzeichen in Deutschland“ (nur die Zuordnung Kürzel → Kreis).
"""
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def xlsx_zeilen(pfad, blatt):
    z = zipfile.ZipFile(pfad)
    ss = [''.join(t.text or '' for t in si.iter('{%s}t' % NS['m']))
          for si in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('m:si', NS)]
    root = ET.fromstring(z.read(f'xl/worksheets/sheet{blatt}.xml'))
    for r in root.iter('{%s}row' % NS['m']):
        zeile = {}
        for c in r.findall('m:c', NS):
            v = c.find('m:v', NS)
            if v is None:
                continue
            spalte = 0
            for ch in re.match(r'[A-Z]+', c.get('r')).group():
                spalte = spalte * 26 + ord(ch) - 64
            zeile[spalte - 1] = ss[int(v.text)] if c.get('t') == 's' else v.text
        yield [zeile.get(i) for i in range(max(zeile) + 1)] if zeile else []


ARTEN = {'41': 'Kreisfreie Stadt', '42': 'Stadtkreis', '43': 'Kreis', '44': 'Landkreis', '45': 'Regionalverband'}


def norm(s):
    # Abkürzungen im Gemeindeverzeichnis ausschreiben (a.d. = an der …).
    for a, b in (('a.d.', 'an der '), ('a.', 'am '), ('i.d.', 'in der '), ('i.', 'im '), ('OPf.', 'Oberpfalz'), ('(Oldb)', '')):
        s = s.replace(a, b)
    s = s.lower().replace('ß', 'ss')
    for a, b in (('ä', 'ae'), ('ö', 'oe'), ('ü', 'ue')):
        s = s.replace(a, b)
    return re.sub(r'[^a-z0-9]+', ' ', s).strip()


def kreise_und_orte(pfad):
    laender, kreise, orte = {}, {}, []
    for z in xlsx_zeilen(pfad, 2):
        if len(z) < 8 or z[0] not in ('10', '40', '60'):
            continue
        if z[0] == '10':
            laender[z[2]] = z[7]
        elif z[0] == '40':
            schluessel = z[2] + z[3] + z[4]
            kreise[schluessel] = {'s': schluessel, 'n': z[7], 'a': ARTEN[z[1]], 'l': laender[z[2]], 'k': []}
        else:
            schluessel = z[2] + z[3] + z[4]
            if len(z) > 15 and z[14] and z[15]:
                orte.append([re.sub(r',.*$', '', z[7]), round(float(z[15].replace(',', '.')), 3),
                             round(float(z[14].replace(',', '.')), 3), schluessel])
    return kreise, orte


def kfz_zuordnen(pfad, kreise):
    text = json.load(open(pfad, encoding='utf-8'))['parse']['wikitext']
    text = text[text.index('=== A ==='):]
    text = re.sub(r'<ref[^>]*/>|<ref[^>]*>.*?</ref>', '', text, flags=re.S)

    def klar(zelle):
        zelle = re.sub(r'^\s*(rowspan|colspan)="\d+"\s*\|', '', zelle)
        zelle = re.sub(r'\[\[[^\]|]*\|([^\]]*)\]\]', r'\1', zelle)
        zelle = re.sub(r'\[\[([^\]]*)\]\]', r'\1', zelle)
        zelle = re.sub(r"'''|''|<[^>]+>|\{\{[^}]*\}\}", '', zelle)
        return zelle.strip()

    # Kreisnamen nach Art für den Abgleich (Stadt X / Landkreis X / X).
    staedte, landkreise, alle = {}, {}, {}
    for k in kreise.values():
        roh = re.sub(r',.*$', '', k['n'])
        namen = {norm(k['n']), norm(roh), norm(re.sub(r'\s*\([^)]*\)', '', roh))}
        if ',' in k['n']:
            namen.add(norm(k['n'].split(',', 1)[1] + ' ' + roh))  # „Freie und Hansestadt Hamburg“
        for basis in namen:
            alle.setdefault(basis, []).append(k['s'])
            (staedte if k['a'] in ('Kreisfreie Stadt', 'Stadtkreis') else landkreise).setdefault(basis, []).append(k['s'])

    def finden(name):
        n = norm(name)
        m = re.match(r'^(stadt|kreisfreie stadt|universitaetsstadt|hansestadt) (.+)$', n)
        if m and m.group(2) in staedte:
            return staedte[m.group(2)]
        m = re.match(r'^(landkreis|kreis|lk) (.+)$', n)
        if m and m.group(2) in landkreise:
            return landkreise[m.group(2)]
        if n in alle and len(set(alle[n])) == 1:
            return alle[n]
        if n in landkreise and len(landkreise[n]) == 1:
            return landkreise[n]
        return None

    fehlend = []
    kuerzel = None
    for zeile in text.split('\n|-'):
        zeile = zeile.split('\n|}')[0]
        zellen = [klar(z) for z in re.split(r'\n\|', '\n' + zeile.strip())[1:] if z.strip()]
        if not zellen:
            continue
        if re.fullmatch(r'[A-ZÄÖÜ]{1,3}', zellen[0]):
            kuerzel, kreiszellen = zellen[0], zellen[1:2]
        elif kuerzel and len(zellen) == 1:
            kreiszellen = zellen
        else:
            continue
        for name in kreiszellen:
            name = name.split('\n')[0]
            # Kreisangehörige Stadt mit eigenem Kürzel: dem Kreis zuordnen.
            m = re.search(r'\((?:[^()]*?) im ((?:Landkreis|Regionalverband|Kreis)?\s*[^(),]+?)(?:,[^()]*)?\)', name)
            if m and finden(m.group(1)):
                name = m.group(1)
            name = re.sub(r'\s*\([^)]*\)\*?|\s+ohne die (Stadt|Gemeinde) .*$', '', name).strip()
            name = re.sub(r', (Senat|Landesregierung).*$', '', name)
            for teil in re.split(r'\s*(?:,|/| und )\s*(?=(?:Stadt|Landkreis|Kreis) )', name):
                treffer = finden(teil)
                if treffer is None:
                    fehlend.append((kuerzel, teil))
                    continue
                for s in treffer:
                    if kuerzel not in kreise[s]['k']:
                        kreise[s]['k'].append(kuerzel)
    return fehlend


def plz_zuordnen(pfad, kreise):
    plz, unbekannt = {}, set()
    for zeile in open(pfad, encoding='utf-8'):
        f = zeile.rstrip('\n').split('\t')
        if len(f) < 9 or not re.fullmatch(r'\d{5}', f[1]):
            continue
        if f[8] not in kreise:
            unbekannt.add(f[8])
            continue
        liste = plz.setdefault(f[1], [])
        if f[8] not in liste:
            liste.append(f[8])
    return plz, unbekannt


def main():
    gv, kfz, geonames = sys.argv[1:4]
    kreise, orte = kreise_und_orte(gv)
    fehlend = kfz_zuordnen(kfz, kreise)
    plz, unbekannt = plz_zuordnen(geonames, kreise)
    ziel = Path(__file__).resolve().parent.parent / 'regionen-de.json'
    daten = {
        'stand': 'Gebietsstand 30.09.2026 (Destatis GV-ISys, 3. Quartal)',
        'quellen': [
            'Kreise und Gemeinden: © Statistisches Bundesamt (Destatis), Gemeindeverzeichnis GV-ISys, dl-de/by-2-0',
            'Postleitzahlen: GeoNames (www.geonames.org), CC BY 4.0',
            'Kfz-Unterscheidungszeichen: Wikipedia, Liste der Kfz-Kennzeichen in Deutschland',
        ],
        'kreise': sorted(kreise.values(), key=lambda k: k['s']),
        'plz': dict(sorted(plz.items())),
        'orte': orte,
    }
    ziel.write_text(json.dumps(daten, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    ohne_kfz = [k['n'] for k in kreise.values() if not k['k']]
    print(f'{len(kreise)} Kreise, {len(orte)} Orte, {len(plz)} PLZ -> {ziel}')
    print(f'Kfz nicht zugeordnet ({len(fehlend)}):', fehlend)
    print(f'Kreise ohne Kfz ({len(ohne_kfz)}):', ohne_kfz)
    print(f'GeoNames-Kreisschlüssel unbekannt ({len(unbekannt)}):', sorted(unbekannt))


if __name__ == '__main__':
    main()
