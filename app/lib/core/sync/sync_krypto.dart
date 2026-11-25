import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../krypto/krypto.dart';
import '../krypto/recovery_schluessel.dart';

/// Kryptografie des privaten Syncs. Alles, was zum Server geht, ist mit
/// AES-256-GCM verschlüsselt; der Server sieht nur Geheimtext, zufällige
/// bzw. gehashte IDs, Revisionen und Größen.
///
/// - **Kontoschlüssel:** 256 Bit Zufall, erzeugt vom ersten Gerät. Er
///   verschlüsselt alle Datensätze und verlässt Geräte nur verschlüsselt:
///   mit dem Kopplungscode (für ein neues Gerät) oder mit dem
///   Recovery-Schlüssel (für den Fall, dass alle Geräte weg sind).
/// - **Objekt-ID:** HMAC über Bereich und Datensatz-ID — der Server erfährt
///   weder den Bereich (Termin, Buchung, …) noch die lokale ID.

String _b64(Uint8List b) => base64Encode(b);
Uint8List _vonB64(String s) => base64Decode(s);

String _verpacken(Uint8List schluessel, Map<String, dynamic> inhalt, String aad) =>
    jsonEncode(AesGcm.verschluesseln(schluessel, Uint8List.fromList(utf8.encode(jsonEncode(inhalt))), aad: aad).toJson());

Map<String, dynamic>? _entpacken(Uint8List schluessel, String text, String aad) {
  try {
    final g = Geheimtext.fromJson(jsonDecode(text));
    if (g == null) return null;
    final klar = AesGcm.entschluesseln(schluessel, g, aad: aad);
    if (klar == null) return null;
    return (jsonDecode(utf8.decode(klar)) as Map).cast<String, dynamic>();
  } on FormatException {
    return null;
  }
}

/// Die aus dem Recovery-Schlüssel abgeleiteten Teile, die ein Gerät für
/// seinen Schlüsselbund braucht. Mit Sync teilen sich alle Geräte eines
/// Kontos denselben Recovery-Schlüssel.
class RecoveryTeile {
  const RecoveryTeile({required this.huellenSchluessel, required this.backupSchluessel, required this.kennung});

  factory RecoveryTeile.von(RecoverySchluessel r) =>
      RecoveryTeile(huellenSchluessel: r.huellenSchluessel, backupSchluessel: r.backupSchluessel, kennung: r.kennung);

  final Uint8List huellenSchluessel;
  final Uint8List backupSchluessel;
  final String kennung;

  Map<String, dynamic> toJson() => {'huelle': _b64(huellenSchluessel), 'backup': _b64(backupSchluessel), 'kennung': kennung};

  static RecoveryTeile fromJson(Map<String, dynamic> j) => RecoveryTeile(
        huellenSchluessel: _vonB64(j['huelle'] as String),
        backupSchluessel: _vonB64(j['backup'] as String),
        kennung: j['kennung'] as String,
      );
}

/// Anmeldung und Schlüsselhülle über den Recovery-Schlüssel.
extension RecoverySync on RecoverySchluessel {
  /// Anmeldegeheimnis für `POST /v1/anmelden/recovery` (der Server
  /// speichert nur dessen SHA-256).
  Uint8List get syncAnmeldung => hkdf(bytes, 'ptv2-sync-anmeldung-v1');
  Uint8List get _syncHuelle => hkdf(bytes, 'ptv2-sync-huelle-v1');

  String huelleFuer(Kontoschluessel k) => _verpacken(_syncHuelle, {'k': _b64(k.bytes)}, _aadRecoveryHuelle);

  Kontoschluessel? kontoschluesselAus(String huelle) {
    final j = _entpacken(_syncHuelle, huelle, _aadRecoveryHuelle);
    return j == null ? null : Kontoschluessel(_vonB64(j['k'] as String));
  }
}

const _aadRecoveryHuelle = 'ptv2-sync-recovery-huelle-v1';
const _aadSchluesselPaket = 'ptv2-sync-schluesselpaket-v1';
const _aadGeraetName = 'ptv2-sync-geraetename-v1';

/// Klartext eines Sync-Objekts.
class Umschlag {
  const Umschlag({required this.bereich, required this.id, required this.schema, this.daten});

  final String bereich;
  final String id;
  final int schema;

  /// `null` = gelöscht.
  final Map<String, dynamic>? daten;
}

class Kontoschluessel {
  Kontoschluessel(this.bytes) : _idSchluessel = hkdf(bytes, 'ptv2-sync-objekt-id-v1');

  factory Kontoschluessel.neu() => Kontoschluessel(zufall(32));

  final Uint8List bytes;
  final Uint8List _idSchluessel;

  /// Serverseitige ID eines Datensatzes (128 Bit HMAC, hex).
  String objektId(String bereich, String id) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(_idSchluessel));
    final out = mac.process(Uint8List.fromList(utf8.encode('$bereich/$id')));
    return hex(Uint8List.sublistView(out, 0, 16));
  }

  /// Verschlüsselt einen Datensatz. Die Länge wird auf 256 Byte
  /// aufgerundet, damit die Größe weniger über den Inhalt verrät.
  String verschluesseln(Umschlag u) {
    final roh = utf8.encode(jsonEncode({'b': u.bereich, 'i': u.id, 's': u.schema, 'd': u.daten}));
    final fuell = (256 - (roh.length + 1) % 256) % 256;
    final klar = Uint8List(roh.length + 1 + fuell)..setRange(0, roh.length, roh);
    klar[roh.length] = 0x0a; // Trenner; danach nur Nullbytes.
    final g = AesGcm.verschluesseln(bytes, klar, aad: 'ptv2-sync-objekt|${objektId(u.bereich, u.id)}');
    return jsonEncode(g.toJson());
  }

  /// `null`, wenn der Geheimtext nicht zu diesem Schlüssel und dieser
  /// Objekt-ID passt (beschädigt, vertauscht oder untergeschoben).
  Umschlag? entschluesseln(String objektId, String daten) {
    try {
      final g = Geheimtext.fromJson(jsonDecode(daten));
      if (g == null) return null;
      final klar = AesGcm.entschluesseln(bytes, g, aad: 'ptv2-sync-objekt|$objektId');
      if (klar == null) return null;
      final ende = klar.indexOf(0x0a);
      final j = (jsonDecode(utf8.decode(ende < 0 ? klar : Uint8List.sublistView(klar, 0, ende))) as Map).cast<String, dynamic>();
      final u = Umschlag(
        bereich: j['b'] as String,
        id: j['i'] as String,
        schema: j['s'] as int,
        daten: (j['d'] as Map?)?.cast<String, dynamic>(),
      );
      // Gegenprobe: die Objekt-ID muss zum Inhalt passen.
      return this.objektId(u.bereich, u.id) == objektId ? u : null;
    } catch (_) {
      return null;
    }
  }

  String schluesselPaket(RecoveryTeile t) => _verpacken(bytes, t.toJson(), _aadSchluesselPaket);

  RecoveryTeile? recoveryTeileAus(String paket) {
    final j = _entpacken(bytes, paket, _aadSchluesselPaket);
    return j == null ? null : RecoveryTeile.fromJson(j);
  }

  String geraetName(String name) => _verpacken(bytes, {'n': name}, _aadGeraetName);

  String? geraetNameAus(String text) => _entpacken(bytes, text, _aadGeraetName)?['n'] as String?;
}

/// Einmaliger Kopplungscode: 20 Zeichen Crockford-Base32 (100 Bit).
/// Daraus folgen der Slot auf dem Server und der Schlüssel für das Paket.
/// Der Server kennt den Code nicht und kann das Paket daher weder lesen
/// noch fälschen.
class Kopplungscode {
  Kopplungscode._(this.text);

  factory Kopplungscode.neu() {
    final z = zufall(20);
    return Kopplungscode._([for (final b in z) _alphabet[b & 31]].join());
  }

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const laenge = 20;

  final String text;

  String anzeigen() => [for (var i = 0; i < laenge; i += 4) text.substring(i, i + 4)].join('-');

  static Kopplungscode? lesen(String eingabe) {
    final s = eingabe
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_.]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (s.length != laenge || s.split('').any((c) => !_alphabet.contains(c))) return null;
    return Kopplungscode._(s);
  }

  Uint8List get _material => Uint8List.fromList(utf8.encode(text));
  String get slot => hex(hkdf(_material, 'ptv2-kopplung-slot-v1'));
  Uint8List get _schluessel => hkdf(_material, 'ptv2-kopplung-paket-v1');

  String paket(String konto, Kontoschluessel k) => _verpacken(_schluessel, {'konto': konto, 'k': _b64(k.bytes)}, 'ptv2-kopplung|$slot');

  /// Paket für eine Agenten-Brücke: zusätzlich Name und Rechte.
  String agentPaket(String konto, Kontoschluessel k, Map<String, dynamic> agent) =>
      _verpacken(_schluessel, {'konto': konto, 'k': _b64(k.bytes), 'agent': agent}, 'ptv2-kopplung|$slot');

  /// [agent]: der Code ist für die Agenten-Brücke `pt-agent` gedacht.
  ({String konto, Kontoschluessel schluessel, bool agent})? paketOeffnen(String paket) {
    final j = _entpacken(_schluessel, paket, 'ptv2-kopplung|$slot');
    if (j == null) return null;
    return (konto: j['konto'] as String, schluessel: Kontoschluessel(_vonB64(j['k'] as String)), agent: j['agent'] != null);
  }
}
