import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/krypto.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';
import 'package:personal_tracker/core/vault/vault_datei.dart';

/// Testvektoren für das Obsidian-Plugin (`protokoll/testvektoren.json`).
/// Neu schreiben: `PT_VEKTOREN=schreiben flutter test test/core/protokoll_test.dart`.
void main() {
  final datei = File('../protokoll/testvektoren.json');
  final ks = Kontoschluessel(Uint8List.fromList(List.generate(32, (i) => i)));
  final block = Uint8List.fromList(utf8.encode('Inhalt eines Blocks ✓'));
  final code = Kopplungscode.lesen('ABCD-EFGH-JKMN-PQRS-TVWX')!;

  Map<String, dynamic> erzeugen() {
    final bid = ks.blockId(block);
    final umschlag = Umschlag(bereich: 'vault', id: 'datei-1', schema: 4, daten: {'id': 'datei-1', 'pfad': 'Ordner/Ä.md'});
    return {
      'hinweis': 'Erzeugt von app/test/core/protokoll_test.dart; Schlüssel nur für Tests.',
      'kontoschluessel': base64Encode(ks.bytes),
      'hkdf': {'material': base64Encode(ks.bytes), 'info': 'ptv2-vault-block-id-v1', 'ergebnis': hex(hkdf(ks.bytes, 'ptv2-vault-block-id-v1'))},
      'objektId': {'bereich': 'vault', 'id': 'datei-1', 'ergebnis': ks.objektId('vault', 'datei-1')},
      'umschlag': {'objektId': ks.objektId('vault', 'datei-1'), 'daten': ks.verschluesseln(umschlag), 'pfad': 'Ordner/Ä.md'},
      'block': {'klar': base64Encode(block), 'id': bid, 'daten': base64Encode(ks.blockVerschluesseln(bid, block))},
      'geraetName': {'daten': ks.geraetName('Laptop'), 'name': 'Laptop'},
      'kopplung': {'code': code.text, 'slot': code.slot, 'paket': code.paket('konto-1', ks)},
    };
  }

  test('Testvektoren passen zur App', () {
    if (Platform.environment['PT_VEKTOREN'] == 'schreiben') {
      datei.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(erzeugen()));
    }
    final v = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
    final k = Kontoschluessel(base64Decode(v['kontoschluessel'] as String));
    expect(hex(hkdf(k.bytes, v['hkdf']['info'] as String)), v['hkdf']['ergebnis']);
    expect(k.objektId('vault', 'datei-1'), v['objektId']['ergebnis']);
    final u = k.entschluesseln(v['umschlag']['objektId'] as String, v['umschlag']['daten'] as String)!;
    expect(u.daten!['pfad'], 'Ordner/Ä.md');
    final b = v['block'] as Map<String, dynamic>;
    expect(k.blockId(base64Decode(b['klar'] as String)), b['id']);
    expect(k.blockEntschluesseln(b['id'] as String, base64Decode(b['daten'] as String), block.length), block);
    expect(k.geraetNameAus(v['geraetName']['daten'] as String), 'Laptop');
    final c = Kopplungscode.lesen(v['kopplung']['code'] as String)!;
    expect(c.slot, v['kopplung']['slot']);
    expect(c.paketOeffnen(v['kopplung']['paket'] as String)!.konto, 'konto-1');
  });
}
