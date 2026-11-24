import 'dart:convert';
import 'dart:typed_data';

import 'secret_muster.g.dart';

/// Ein Treffer der Secret-Erkennung: welche Regel in welcher Zeile. Den
/// gefundenen Wert gibt es bewusst nicht — er soll weder in Warnungen
/// noch in Protokollen auftauchen.
typedef SecretTreffer = ({String regel, int zeile});

class _Regel {
  _Regel(this.name, this.muster, this.wert);
  final String name;
  final RegExp muster;

  /// Gruppe mit dem eigentlichen Wert (für den Platzhalter-Ausschluss).
  final int? wert;
}

/// Erkennung von Secrets vor dem Hochladen (Muster aus
/// `protokoll/secret-muster.json`, dieselben wie im Obsidian-Plugin).
///
/// Die Erkennung kann Secrets übersehen (andere Formate, Binärdateien) und
/// harmlose Stellen melden. Sie ersetzt keine eigene Prüfung.
class SecretPruefung {
  SecretPruefung._(this._regeln, this._platzhalter);

  factory SecretPruefung.standard() => _standard ??= SecretPruefung.ausJson(secretMusterJson);
  static SecretPruefung? _standard;

  factory SecretPruefung.ausJson(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    return SecretPruefung._(
      [
        for (final r in (j['regeln'] as List).cast<Map<String, dynamic>>())
          _Regel(
            r['name'] as String,
            RegExp(r['muster'] as String, caseSensitive: !((r['flags'] as String?) ?? '').contains('i')),
            r['wert'] as int?,
          ),
      ],
      RegExp(j['platzhalter'] as String, caseSensitive: false),
    );
  }

  final List<_Regel> _regeln;
  final RegExp _platzhalter;

  /// Dateien darüber werden nicht durchsucht (gelten als ungeprüft).
  static const maxGroesse = 10 * 1024 * 1024;

  /// Text oder Binärdatei? Binär = Nullbyte in den ersten 8 KiB.
  static bool istText(Uint8List b) {
    final n = b.length < 8192 ? b.length : 8192;
    for (var i = 0; i < n; i++) {
      if (b[i] == 0) return false;
    }
    return true;
  }

  /// `null`, wenn die Datei nicht geprüft werden kann (binär oder zu groß).
  List<SecretTreffer>? pruefen(Uint8List inhalt) {
    if (inhalt.length > maxGroesse || !istText(inhalt)) return null;
    return pruefeText(utf8.decode(inhalt, allowMalformed: true));
  }

  List<SecretTreffer> pruefeText(String text) {
    final treffer = <SecretTreffer>[];
    final zeilen = text.split('\n');
    for (var z = 0; z < zeilen.length; z++) {
      for (final r in _regeln) {
        for (final m in r.muster.allMatches(zeilen[z])) {
          final w = r.wert == null ? null : m.group(r.wert!);
          if (w != null && _platzhalter.hasMatch(w.replaceAll(RegExp(r'[,;.)\]]+$'), ''))) continue;
          treffer.add((regel: r.name, zeile: z + 1));
          break;
        }
      }
    }
    return treffer;
  }
}
