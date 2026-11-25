#!/usr/bin/env python3
"""Verteilt protokoll/regionen-de.json und protokoll/ketten-de.json an App und Server.

    python3 -I protokoll/regionen/kopieren.py

- App: app/assets/regionen-de.json und app/assets/ketten-de.json (unverändert).
- Server: server/lib/src/regionen.g.dart mit Kreisen (ohne PLZ und Orte) und Ketten.
Tests in App und Server prüfen die Gleichheit.
"""
import json
import shutil
from pathlib import Path

wurzel = Path(__file__).resolve().parents[2]
protokoll = wurzel / 'protokoll'
for name in ('regionen-de.json', 'ketten-de.json'):
    shutil.copyfile(protokoll / name, wurzel / 'app' / 'assets' / name)

regionen = json.loads((protokoll / 'regionen-de.json').read_text(encoding='utf-8'))
ketten = (protokoll / 'ketten-de.json').read_text(encoding='utf-8')
kreise = json.dumps({'stand': regionen['stand'], 'kreise': regionen['kreise']}, ensure_ascii=False, separators=(',', ':'))
assert "'''" not in kreise + ketten
(wurzel / 'server' / 'lib' / 'src' / 'regionen.g.dart').write_text(
    '// Erzeugt aus protokoll/regionen-de.json und protokoll/ketten-de.json\n'
    '// (protokoll/regionen/kopieren.py); der Test prüft die Gleichheit.\n'
    f"const kreiseJson = r'''{kreise}''';\n\n"
    f"const kettenJson = r'''{ketten}''';\n",
    encoding='utf-8')
print('kopiert')
