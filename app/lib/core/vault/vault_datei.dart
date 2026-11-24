import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../krypto/krypto.dart';
import '../sync/sync_krypto.dart';

/// Bereich der Vault-Dateien im Sync (Umschlag `b`). Derselbe Vertrag gilt
/// für das Obsidian-Plugin; siehe `protokoll/VAULT.md`.
const vaultBereich = 'vault';

/// Kleinere Dateien liegen direkt im Objekt, größere in Blöcken.
const vaultInlineGrenze = 64 * 1024;

/// Klartextgröße eines Blocks.
const vaultBlockGroesse = 1024 * 1024;

/// Blöcke werden auf ein Vielfaches davon aufgefüllt.
const _blockRaster = 4096;

typedef BlockRef = ({String id, int groesse});

/// Eine Datei des Vaults. Die ID ist stabil und unabhängig vom Pfad;
/// Umbenennen ändert nur [pfad].
class VaultDatei {
  const VaultDatei({
    required this.id,
    required this.pfad,
    required this.groesse,
    required this.sha256,
    this.inhalt,
    this.bloecke = const [],
    required this.geaendert,
  });

  final String id;

  /// Relativ zur Vault-Wurzel, mit `/` getrennt.
  final String pfad;
  final int groesse;

  /// SHA-256 des Inhalts (hex).
  final String sha256;

  /// Inhalt kleiner Dateien (bis [vaultInlineGrenze]).
  final Uint8List? inhalt;
  final List<BlockRef> bloecke;
  final DateTime geaendert;

  String get name => pfad.split('/').last;
  String get ordner => pfad.contains('/') ? pfad.substring(0, pfad.lastIndexOf('/')) : '';
  String get endung => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
  bool get istMarkdown => endung == 'md';
  bool get istBild => const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(endung);

  VaultDatei kopie({String? id, String? pfad, DateTime? geaendert}) => VaultDatei(
        id: id ?? this.id,
        pfad: pfad ?? this.pfad,
        groesse: groesse,
        sha256: sha256,
        inhalt: inhalt,
        bloecke: bloecke,
        geaendert: geaendert ?? this.geaendert,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'pfad': pfad,
        'groesse': groesse,
        'sha256': sha256,
        if (inhalt != null) 'inhalt': base64Encode(inhalt!),
        if (inhalt == null) 'bloecke': [for (final b in bloecke) {'id': b.id, 'groesse': b.groesse}],
        'geaendert': geaendert.toUtc().toIso8601String(),
      };

  static VaultDatei fromJson(Map<String, dynamic> j) => VaultDatei(
        id: j['id'] as String,
        pfad: j['pfad'] as String,
        groesse: j['groesse'] as int,
        sha256: j['sha256'] as String,
        inhalt: j['inhalt'] == null ? null : base64Decode(j['inhalt'] as String),
        bloecke: [
          for (final b in ((j['bloecke'] as List?) ?? const []).cast<Map<String, dynamic>>())
            (id: b['id'] as String, groesse: b['groesse'] as int),
        ],
        geaendert: DateTime.parse(j['geaendert'] as String),
      );
}

String sha256Hex(List<int> daten) => sha256.convert(daten).toString();

/// Prüft und normalisiert einen Vault-Pfad. Wirft bei absoluten Pfaden,
/// `..`, leeren Teilen oder Steuerzeichen — ein Objekt vom Server darf
/// nie außerhalb des Vaults schreiben.
String vaultPfad(String pfad) {
  final p = pfad.replaceAll('\\', '/');
  final teile = p.split('/');
  if (p.isEmpty ||
      p.startsWith('/') ||
      teile.any((t) => t.isEmpty || t == '.' || t == '..') ||
      RegExp(r'[\x00-\x1f]').hasMatch(p) ||
      RegExp(r'^[A-Za-z]:').hasMatch(p)) {
    throw FormatException('Ungültiger Vault-Pfad: $pfad');
  }
  return p;
}

/// Name einer Konfliktkopie: „Notiz (Konflikt 2026-11-24 1403 Handy).md“
/// im selben Ordner; ist der Name vergeben, kommt eine Zahl dazu.
String konfliktPfad(String pfad, DateTime zeit, String geraet, bool Function(String) vergeben) {
  final i = pfad.lastIndexOf('/');
  final ordner = i < 0 ? '' : pfad.substring(0, i + 1);
  final name = pfad.substring(i + 1);
  final p = name.lastIndexOf('.');
  final basis = p > 0 ? name.substring(0, p) : name;
  final endung = p > 0 ? name.substring(p) : '';
  final t = zeit.toLocal();
  String zwei(int n) => n.toString().padLeft(2, '0');
  final stempel = '${t.year}-${zwei(t.month)}-${zwei(t.day)} ${zwei(t.hour)}${zwei(t.minute)}';
  final g = geraet.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '').trim();
  final kern = '$basis (Konflikt $stempel${g.isEmpty ? '' : ' $g'}';
  var kandidat = '$ordner$kern)$endung';
  for (var n = 2; vergeben(kandidat); n++) {
    kandidat = '$ordner$kern $n)$endung';
  }
  return kandidat;
}

/// Blockverschlüsselung der Vault-Dateien mit dem Kontoschlüssel.
extension VaultKrypto on Kontoschluessel {
  Uint8List get _blockIdSchluessel => hkdf(bytes, 'ptv2-vault-block-id-v1');

  /// Inhaltsadresse eines Blocks: HMAC-SHA256 unter einem eigenen
  /// Schlüssel (128 Bit, hex). Der Server kann so keine bekannten Dateien
  /// über ihren Hash erkennen.
  String blockId(Uint8List klar) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(_blockIdSchluessel));
    return hex(Uint8List.sublistView(mac.process(klar), 0, 16));
  }

  /// `nonce (12) || Geheimtext mit Tag`; der Klartext wird mit Nullbytes
  /// auf ein Vielfaches von 4 KiB aufgefüllt.
  Uint8List blockVerschluesseln(String id, Uint8List klar) {
    final laenge = ((klar.length + _blockRaster - 1) ~/ _blockRaster) * _blockRaster;
    final gefuellt = Uint8List(laenge == 0 ? _blockRaster : laenge)..setRange(0, klar.length, klar);
    final g = AesGcm.verschluesseln(bytes, gefuellt, aad: 'ptv2-vault-block|$id');
    return Uint8List(12 + g.daten.length)
      ..setRange(0, 12, g.nonce)
      ..setRange(12, 12 + g.daten.length, g.daten);
  }

  /// `null`, wenn der Block nicht passt (falscher Schlüssel, beschädigt
  /// oder unter falscher ID geliefert).
  Uint8List? blockEntschluesseln(String id, Uint8List daten, int groesse) {
    if (daten.length < 28) return null;
    final klar = AesGcm.entschluesseln(
      bytes,
      Geheimtext(Uint8List.sublistView(daten, 0, 12), Uint8List.sublistView(daten, 12)),
      aad: 'ptv2-vault-block|$id',
    );
    if (klar == null || klar.length < groesse) return null;
    final inhalt = Uint8List.fromList(Uint8List.sublistView(klar, 0, groesse));
    return blockId(inhalt) == id ? inhalt : null;
  }

  /// Datei-Datensatz aus einem Inhalt bilden. Große Inhalte werden in
  /// Blöcke geteilt; die verschlüsselten Blöcke kommen in [neueBloecke].
  VaultDatei vaultDatei({
    required String id,
    required String pfad,
    required Uint8List inhalt,
    required DateTime geaendert,
    Map<String, Uint8List>? neueBloecke,
  }) {
    final hash = sha256Hex(inhalt);
    if (inhalt.length <= vaultInlineGrenze) {
      return VaultDatei(id: id, pfad: pfad, groesse: inhalt.length, sha256: hash, inhalt: inhalt, geaendert: geaendert);
    }
    final refs = <BlockRef>[];
    for (var i = 0; i < inhalt.length; i += vaultBlockGroesse) {
      final teil = Uint8List.sublistView(inhalt, i, i + vaultBlockGroesse > inhalt.length ? inhalt.length : i + vaultBlockGroesse);
      final bid = blockId(teil);
      refs.add((id: bid, groesse: teil.length));
      neueBloecke?[bid] = teil;
    }
    return VaultDatei(id: id, pfad: pfad, groesse: inhalt.length, sha256: hash, bloecke: refs, geaendert: geaendert);
  }
}
