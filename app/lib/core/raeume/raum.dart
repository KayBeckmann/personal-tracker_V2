import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../krypto/krypto.dart';
import '../sync/sync_krypto.dart';

/// Was ein Raum teilt.
enum RaumArt {
  vault('Vault-Ordner'),
  kalender('Kalender'),
  aufgaben('Aufgabenliste');

  const RaumArt(this.titel);
  final String titel;
}

/// Ein Mitglied aus Sicht des Eigentümers.
class Mitglied {
  const Mitglied({required this.konto, required this.name, required this.recht, required this.paar});

  final String konto;
  final String name;

  /// `lesen` oder `schreiben`.
  final String recht;
  final Uint8List paar;

  Mitglied mit({String? recht, String? name}) => Mitglied(konto: konto, name: name ?? this.name, recht: recht ?? this.recht, paar: paar);

  Map<String, dynamic> toJson() => {'konto': konto, 'name': name, 'recht': recht, 'paar': base64Encode(paar)};
  static Mitglied fromJson(Map<String, dynamic> j) =>
      Mitglied(konto: j['konto'] as String, name: j['name'] as String, recht: j['recht'] as String, paar: base64Decode(j['paar'] as String));
}

/// Offene Einladung (Eigentümer): ihr Paarschlüssel erkennt das neue
/// Mitglied an seiner Antwort (verschlüsselt für [slot]).
typedef OffeneEinladung = ({String slot, Uint8List paar, String recht, DateTime bis});

/// Ein geteilter Bereich (siehe `protokoll/RAEUME.md`). Liegt als
/// Datensatz `raeume/<id>` im eigenen Konto, damit alle eigenen Geräte
/// ihn kennen.
class Raum {
  const Raum({
    required this.id,
    required this.art,
    required this.name,
    required this.recht,
    this.von = '',
    required this.idSchluessel,
    required this.schluessel,
    required this.epoche,
    this.paar,
    this.mitglieder = const [],
    this.einladungen = const [],
    this.ordner,
    this.mitgliederNamen = const [],
  });

  final String id;
  final RaumArt art;
  final String name;

  /// `eigentuemer`, `schreiben` oder `lesen`.
  final String recht;

  /// Name des Eigentümers (für Mitglieder).
  final String von;
  final Uint8List idSchluessel;

  /// Raumschlüssel je Epoche.
  final Map<int, Uint8List> schluessel;
  final int epoche;

  /// Paarschlüssel mit dem Eigentümer (nur Mitglieder).
  final Uint8List? paar;
  final List<Mitglied> mitglieder;
  final List<OffeneEinladung> einladungen;

  /// Vault: Ordner auf diesem Konto (Eigentümer: der geteilte Ordner,
  /// Mitglied: wohin der Raum eingehängt ist).
  final String? ordner;

  /// Mitglieder laut Raum-Info (für Mitglieder sichtbar).
  final List<({String name, String recht})> mitgliederNamen;

  bool get eigen => recht == 'eigentuemer';
  bool get schreibbar => recht != 'lesen';
  Uint8List get aktuellerSchluessel => schluessel[epoche]!;

  Raum kopie({
    String? name,
    String? recht,
    Map<int, Uint8List>? schluessel,
    int? epoche,
    List<Mitglied>? mitglieder,
    List<OffeneEinladung>? einladungen,
    String? Function()? ordner,
    List<({String name, String recht})>? mitgliederNamen,
    String? von,
  }) =>
      Raum(
        id: id,
        art: art,
        name: name ?? this.name,
        recht: recht ?? this.recht,
        von: von ?? this.von,
        idSchluessel: idSchluessel,
        schluessel: schluessel ?? this.schluessel,
        epoche: epoche ?? this.epoche,
        paar: paar,
        mitglieder: mitglieder ?? this.mitglieder,
        einladungen: einladungen ?? this.einladungen,
        ordner: ordner != null ? ordner() : this.ordner,
        mitgliederNamen: mitgliederNamen ?? this.mitgliederNamen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'art': art.name,
        'name': name,
        'recht': recht,
        'von': von,
        'idSchluessel': base64Encode(idSchluessel),
        'schluessel': {for (final e in schluessel.entries) '${e.key}': base64Encode(e.value)},
        'epoche': epoche,
        if (paar != null) 'paar': base64Encode(paar!),
        'mitglieder': [for (final m in mitglieder) m.toJson()],
        'einladungen': [
          for (final e in einladungen) {'slot': e.slot, 'paar': base64Encode(e.paar), 'recht': e.recht, 'bis': e.bis.toUtc().toIso8601String()},
        ],
        if (ordner != null) 'ordner': ordner,
        'mitgliederNamen': [for (final m in mitgliederNamen) {'name': m.name, 'recht': m.recht}],
      };

  static Raum fromJson(Map<String, dynamic> j) => Raum(
        id: j['id'] as String,
        art: RaumArt.values.byName(j['art'] as String),
        name: j['name'] as String,
        recht: j['recht'] as String,
        von: (j['von'] as String?) ?? '',
        idSchluessel: base64Decode(j['idSchluessel'] as String),
        schluessel: {for (final e in (j['schluessel'] as Map).entries) int.parse('${e.key}'): base64Decode(e.value as String)},
        epoche: j['epoche'] as int,
        paar: j['paar'] == null ? null : base64Decode(j['paar'] as String),
        mitglieder: [for (final m in ((j['mitglieder'] as List?) ?? const []).cast<Map<String, dynamic>>()) Mitglied.fromJson(m)],
        einladungen: [
          for (final e in ((j['einladungen'] as List?) ?? const []).cast<Map<String, dynamic>>())
            (slot: e['slot'] as String, paar: base64Decode(e['paar'] as String), recht: e['recht'] as String, bis: DateTime.parse(e['bis'] as String)),
        ],
        ordner: j['ordner'] as String?,
        mitgliederNamen: [
          for (final m in ((j['mitgliederNamen'] as List?) ?? const []).cast<Map<String, dynamic>>())
            (name: m['name'] as String, recht: m['recht'] as String),
        ],
      );

  // -----------------------------------------------------------------
  // Kryptografie (protokoll/RAEUME.md)

  static String _hmacHex(Uint8List schluessel, Uint8List daten) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(schluessel));
    return hex(Uint8List.sublistView(mac.process(daten), 0, 16));
  }

  String objektId(String bereich, String id) => _hmacHex(idSchluessel, Uint8List.fromList(utf8.encode('$bereich/$id')));

  String _aad(String oid) => 'ptv2-raum-objekt|$id|$oid';

  String verschluesseln(Umschlag u) {
    final roh = utf8.encode(jsonEncode({'b': u.bereich, 'i': u.id, 's': u.schema, 'd': u.daten}));
    final fuell = (256 - (roh.length + 1) % 256) % 256;
    final klar = Uint8List(roh.length + 1 + fuell)..setRange(0, roh.length, roh);
    klar[roh.length] = 0x0a;
    final g = AesGcm.verschluesseln(aktuellerSchluessel, klar, aad: _aad(objektId(u.bereich, u.id)));
    return jsonEncode({'e': epoche, ...g.toJson()});
  }

  /// `null`, wenn nicht lesbar (unbekannte Epoche, falscher Raum, vertauscht).
  Umschlag? entschluesseln(String oid, String daten) {
    try {
      final j = jsonDecode(daten) as Map<String, dynamic>;
      final k = schluessel[j['e'] as int];
      final g = Geheimtext.fromJson(j);
      if (k == null || g == null) return null;
      final klar = AesGcm.entschluesseln(k, g, aad: _aad(oid));
      if (klar == null) return null;
      final ende = klar.indexOf(0x0a);
      final u = (jsonDecode(utf8.decode(ende < 0 ? klar : Uint8List.sublistView(klar, 0, ende))) as Map).cast<String, dynamic>();
      final r = Umschlag(bereich: u['b'] as String, id: u['i'] as String, schema: u['s'] as int, daten: (u['d'] as Map?)?.cast<String, dynamic>());
      return objektId(r.bereich, r.id) == oid ? r : null;
    } catch (_) {
      return null;
    }
  }

  String blockId(Uint8List klar) => _hmacHex(hkdf(idSchluessel, 'ptv2-raum-block-id-v1'), klar);

  Uint8List blockVerschluesseln(String bid, Uint8List klar) {
    final laenge = ((klar.length + 4095) ~/ 4096) * 4096;
    final gefuellt = Uint8List(laenge == 0 ? 4096 : laenge)..setRange(0, klar.length, klar);
    final g = AesGcm.verschluesseln(aktuellerSchluessel, gefuellt, aad: 'ptv2-raum-block|$id|$bid');
    final out = Uint8List(4 + 12 + g.daten.length);
    ByteData.sublistView(out).setUint32(0, epoche);
    out
      ..setRange(4, 16, g.nonce)
      ..setRange(16, out.length, g.daten);
    return out;
  }

  Uint8List? blockEntschluesseln(String bid, Uint8List daten, int groesse) {
    if (daten.length < 32) return null;
    final k = schluessel[ByteData.sublistView(daten).getUint32(0)];
    if (k == null) return null;
    final klar = AesGcm.entschluesseln(k, Geheimtext(Uint8List.sublistView(daten, 4, 16), Uint8List.sublistView(daten, 16)), aad: 'ptv2-raum-block|$id|$bid');
    if (klar == null || klar.length < groesse) return null;
    final inhalt = Uint8List.fromList(Uint8List.sublistView(klar, 0, groesse));
    return blockId(inhalt) == bid ? inhalt : null;
  }

  /// Raumschlüssel für ein Mitglied, verpackt mit dessen Paarschlüssel.
  String mitgliedPaket(Uint8List paarSchluessel) => jsonEncode(AesGcm.verschluesseln(
        paarSchluessel,
        Uint8List.fromList(utf8.encode(jsonEncode({
          'epoche': epoche,
          'schluessel': {for (final e in schluessel.entries) '${e.key}': base64Encode(e.value)},
        }))),
        aad: 'ptv2-raum-mitglied|$id',
      ).toJson());

  static ({int epoche, Map<int, Uint8List> schluessel})? mitgliedPaketOeffnen(String raum, Uint8List paarSchluessel, String paket) {
    final j = _oeffnen(paarSchluessel, paket, 'ptv2-raum-mitglied|$raum');
    if (j == null) return null;
    return (
      epoche: j['epoche'] as int,
      schluessel: {for (final e in (j['schluessel'] as Map).entries) int.parse('${e.key}'): base64Decode(e.value as String)},
    );
  }

  /// Antwort der eingeladenen Person (ihr Name), für den Eigentümer.
  static String antwort(String slot, Uint8List paarSchluessel, String name) => jsonEncode(
      AesGcm.verschluesseln(paarSchluessel, Uint8List.fromList(utf8.encode(jsonEncode({'name': name}))), aad: 'ptv2-raum-antwort|$slot').toJson());

  static String? antwortName(String slot, Uint8List paarSchluessel, String antwort) =>
      _oeffnen(paarSchluessel, antwort, 'ptv2-raum-antwort|$slot')?['name'] as String?;

  static Map<String, dynamic>? _oeffnen(Uint8List k, String text, String aad) {
    try {
      final g = Geheimtext.fromJson(jsonDecode(text));
      final klar = g == null ? null : AesGcm.entschluesseln(k, g, aad: aad);
      return klar == null ? null : (jsonDecode(utf8.decode(klar)) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

/// Einmaliger Einladungscode (20 Zeichen Crockford-Base32, 100 Bit).
class Einladungscode {
  Einladungscode._(this.text);

  factory Einladungscode.neu() => Einladungscode._(Kopplungscode.neu().text);

  static Einladungscode? lesen(String eingabe) {
    final k = Kopplungscode.lesen(eingabe);
    return k == null ? null : Einladungscode._(k.text);
  }

  final String text;

  String anzeigen() => [for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4)].join('-');

  Uint8List get _material => Uint8List.fromList(utf8.encode(text));
  String get slot => hex(hkdf(_material, 'ptv2-einladung-slot-v1'));
  Uint8List get _schluessel => hkdf(_material, 'ptv2-einladung-paket-v1');

  /// Paarschlüssel zwischen Eigentümer und dieser Person. Beide kennen
  /// den Code, der Server nicht.
  Uint8List get paar => hkdf(_material, 'ptv2-einladung-paar-v1');

  String paket(Raum r, String von) => jsonEncode(AesGcm.verschluesseln(
        _schluessel,
        Uint8List.fromList(utf8.encode(jsonEncode({
          'raum': r.id,
          'art': r.art.name,
          'name': r.name,
          'von': von,
          'idSchluessel': base64Encode(r.idSchluessel),
        }))),
        aad: 'ptv2-einladung|$slot',
      ).toJson());

  ({String raum, RaumArt art, String name, String von, Uint8List idSchluessel})? paketOeffnen(String paket) {
    final j = Raum._oeffnen(_schluessel, paket, 'ptv2-einladung|$slot');
    if (j == null) return null;
    try {
      return (
        raum: j['raum'] as String,
        art: RaumArt.values.byName(j['art'] as String),
        name: j['name'] as String,
        von: j['von'] as String,
        idSchluessel: base64Decode(j['idSchluessel'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
