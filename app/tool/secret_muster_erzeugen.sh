#!/usr/bin/env bash
# Schreibt protokoll/secret-muster.json als Dart-Konstante nach
# lib/core/vault/secret_muster.g.dart (test/core/vault_test.dart prüft die Gleichheit).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
j = open('../protokoll/secret-muster.json', encoding='utf-8').read()
assert "'''" not in j
open('lib/core/vault/secret_muster.g.dart', 'w', encoding='utf-8').write(
    "// Kopie von protokoll/secret-muster.json (Test prüft Gleichheit).\n"
    "// Erzeugen: tool/secret_muster_erzeugen.sh\n"
    "const secretMusterJson = r'''" + j + "''';\n")
PY
