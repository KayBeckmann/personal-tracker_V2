import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_tracker/core/krypto/krypto.dart';
import 'package:personal_tracker/core/raeume/raum.dart';
import 'package:personal_tracker/core/speicher/schema.dart';
import 'package:personal_tracker/core/sync/sync_krypto.dart';
import 'package:personal_tracker/core/vault/vault_datei.dart';

/// Testvektoren für das Obsidian-Plugin (`protokoll/testvektoren.json`).
/// Neu schreiben: `PT_VEKTOREN=schreiben flutter test test/core/protokoll_test.dart`.
void main() {
  final datei = File('../protokoll/testvektoren.json');
  final ks = Kontoschluessel(Uint8List.fromList(List.generate(32, (i) => i)));
  final block = Uint8List.fromList(utf8.encode('Inhalt eines Blocks ✓'));
  final code = Kopplungscode.lesen('ABCD-EFGH-JKMN-PQRS-TVWX')!;
  final raum = Raum(
    id: '0123456789abcdef0123456789abcdef',
    art: RaumArt.vault,
    name: 'Familie',
    recht: 'schreiben',
    idSchluessel: Uint8List.fromList(List.generate(32, (i) => 100 + i)),
    schluessel: {1: Uint8List.fromList(List.generate(32, (i) => 200 - i)), 2: Uint8List.fromList(List.generate(32, (i) => i * 3))},
    epoche: 2,
  );

  Map<String, dynamic> erzeugen() {
    final bid = ks.blockId(block);
    final umschlag = Umschlag(bereich: 'vault', id: 'datei-1', schema: 4, daten: {'id': 'datei-1', 'pfad': 'Ordner/Ä.md'});
    return {
      'hinweis': 'Erzeugt von app/test/core/protokoll_test.dart; Schlüssel nur für Tests.',
      'schema': aktuellesSchema,
      'kontoschluessel': base64Encode(ks.bytes),
      'hkdf': {'material': base64Encode(ks.bytes), 'info': 'ptv2-vault-block-id-v1', 'ergebnis': hex(hkdf(ks.bytes, 'ptv2-vault-block-id-v1'))},
      'objektId': {'bereich': 'vault', 'id': 'datei-1', 'ergebnis': ks.objektId('vault', 'datei-1')},
      'umschlag': {'objektId': ks.objektId('vault', 'datei-1'), 'daten': ks.verschluesseln(umschlag), 'pfad': 'Ordner/Ä.md'},
      'block': {'klar': base64Encode(block), 'id': bid, 'daten': base64Encode(ks.blockVerschluesseln(bid, block))},
      'geraetName': {'daten': ks.geraetName('Laptop'), 'name': 'Laptop'},
      'kopplung': {'code': code.text, 'slot': code.slot, 'paket': code.paket('konto-1', ks)},
      'raum': {
        'json': raum.toJson(),
        'objektId': raum.objektId('vault', 'datei-1'),
        'umschlag': raum.verschluesseln(const Umschlag(bereich: 'vault', id: 'datei-1', schema: 5, daten: {'pfad': 'Plan.md'})),
        'blockId': raum.blockId(block),
        'block': base64Encode(raum.blockVerschluesseln(raum.blockId(block), block)),
        'mitgliedPaar': base64Encode(Uint8List.fromList(List.generate(32, (i) => 7))),
        'mitgliedPaket': raum.mitgliedPaket(Uint8List.fromList(List.generate(32, (i) => 7))),
      },
    };
  }

  test('Testvektoren passen zur App', () {
    if (Platform.environment['PT_VEKTOREN'] == 'schreiben') {
      datei.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(erzeugen()));
    }
    final v = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;
    expect(v['schema'], aktuellesSchema, reason: 'Schema geändert: Testvektoren neu schreiben und SCHEMA im Plugin anpassen');
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
    final rv = v['raum'] as Map<String, dynamic>;
    final r = Raum.fromJson((rv['json'] as Map).cast<String, dynamic>());
    expect(r.objektId('vault', 'datei-1'), rv['objektId']);
    expect(r.entschluesseln(rv['objektId'] as String, rv['umschlag'] as String)!.daten, {'pfad': 'Plan.md'});
    expect(r.blockEntschluesseln(rv['blockId'] as String, base64Decode(rv['block'] as String), block.length), block);
    expect(Raum.mitgliedPaketOeffnen(r.id, base64Decode(rv['mitgliedPaar'] as String), rv['mitgliedPaket'] as String)!.epoche, 2);
  });
}
