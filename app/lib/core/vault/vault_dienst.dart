import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../sitzung.dart';
import '../sync/sync_api.dart';
import '../sync/sync_dienst.dart';
import '../sync/sync_motor.dart';
import '../sync/sync_stand.dart';
import 'secrets.dart';
import 'vault_datei.dart';
import 'vault_stand.dart';

final vaultProvider = NotifierProvider<VaultNotifier, VaultZustand>(VaultNotifier.new);

class VaultZustand {
  const VaultZustand({this.dateien = const [], this.ausstehend = const {}, this.geladen = false});

  /// Nach Pfad sortiert.
  final List<VaultDatei> dateien;

  /// IDs der Dateien mit Änderungen, die noch nicht beim Server sind.
  final Set<String> ausstehend;
  final bool geladen;

  bool get leer => dateien.isEmpty;
}

class VaultFehler implements Exception {
  VaultFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Vault-Dateien in der App: anzeigen, Markdown bearbeiten, anlegen,
/// umbenennen, löschen. Alles läuft über dieselbe Ablage und Sperre wie
/// die übrigen Daten; Änderungen werden zum Senden vorgemerkt.
class VaultNotifier extends Notifier<VaultZustand> {
  static const _uuid = Uuid();

  @override
  VaultZustand build() {
    ref.listen(sitzungProvider, (vorher, jetzt) {
      if (jetzt is Entsperrt && vorher is! Entsperrt) {
        unawaited(laden());
      } else if (jetzt is! Entsperrt) {
        state = const VaultZustand();
      }
    });
    ref.listen(syncProvider.select((s) => (s.letzter, s.ausstehend)), (_, _) => unawaited(laden()));
    if (ref.read(sitzungProvider) is Entsperrt) unawaited(laden());
    return const VaultZustand();
  }

  Entsperrt get _offen {
    final s = ref.read(sitzungProvider);
    if (s is! Entsperrt) throw StateError('Nicht entsperrt');
    return s;
  }

  VaultStand _stand() => VaultStand(ref.read(ablageProvider), _offen.dek);
  SitzungNotifier get _sitzung => ref.read(sitzungProvider.notifier);

  int _ladeLauf = 0;

  Future<void> laden() async {
    if (ref.read(sitzungProvider) is! Entsperrt) return;
    // Nur das zuletzt begonnene Laden zählt (sonst könnte ein älteres,
    // später fertiges Laden einen neueren Stand überschreiben).
    final lauf = ++_ladeLauf;
    final dateien = await _stand().alle()
      ..sort((a, b) => a.pfad.toLowerCase().compareTo(b.pfad.toLowerCase()));
    final ausgang = await SyncStand(ref.read(ablageProvider), _offen.dek).ausgang();
    if (!ref.mounted || ref.read(sitzungProvider) is! Entsperrt || lauf != _ladeLauf) return;
    state = VaultZustand(
      dateien: dateien,
      ausstehend: {
        for (final k in ausgang.keys)
          if (SyncStand.teile(k).$1 == vaultBereich) SyncStand.teile(k).$2,
      },
      geladen: true,
    );
  }

  /// Inhalt einer Datei: direkt, aus dem Zwischenspeicher oder vom Server
  /// (dann zwischengespeichert). Prüft den Hash.
  Future<Uint8List> inhalt(VaultDatei d) async {
    if (d.inhalt != null) return d.inhalt!;
    final stand = _stand();
    final teile = BytesBuilder(copy: false);
    SyncApi? api;
    Verbindung? v;
    final raum = d.blockOrt == null ? null : _offen.bestand.raeume[d.blockOrt];
    if (d.blockOrt != null && raum == null) throw VaultFehler('Diese Datei gehört zu einer Freigabe, auf die du keinen Zugriff mehr hast.');
    for (final b in d.bloecke) {
      var klar = await stand.block(b.id);
      if (klar == null) {
        v ??= await SyncStand(ref.read(ablageProvider), _offen.dek).verbindung();
        if (v == null) throw VaultFehler('Diese Datei ist nur auf dem Server, und die App ist nicht verbunden.');
        api ??= SyncApi(serverAdresse(v.server), client: ref.read(httpClientProvider), token: v.token);
        final geheim = await api.blockLesen(b.id, raum: raum?.id);
        klar = raum != null ? raum.blockEntschluesseln(b.id, geheim, b.groesse) : v.schluessel.blockEntschluesseln(b.id, geheim, b.groesse);
        if (klar == null) throw VaultFehler('Ein Teil der Datei ließ sich nicht entschlüsseln.');
        await stand.blockSpeichern(b.id, klar);
      }
      teile.add(klar);
    }
    final alles = teile.takeBytes();
    if (sha256Hex(alles) != d.sha256) throw VaultFehler('Die Datei ist unvollständig oder beschädigt.');
    return alles;
  }

  Future<String> text(VaultDatei d) async => utf8.decode(await inhalt(d), allowMalformed: true);

  VaultDatei? _anPfad(String pfad) =>
      state.dateien.where((d) => d.pfad.toLowerCase() == pfad.toLowerCase()).firstOrNull;

  /// Neue Datei oder neuer Inhalt für [alt]. Liefert den gespeicherten
  /// Datensatz.
  Future<VaultDatei> speichern({VaultDatei? alt, required String pfad, required Uint8List inhalt}) async {
    final p = _pruefePfad(pfad, alt);
    final v = await SyncStand(ref.read(ablageProvider), _offen.dek).verbindung();
    if (v == null) throw VaultFehler('Der Vault ist nur mit einer Sync-Verbindung verfügbar.');
    final bloecke = <String, Uint8List>{};
    final d = v.schluessel.vaultDatei(
      id: alt?.id ?? _uuid.v4(),
      pfad: p,
      inhalt: inhalt,
      geaendert: ref.read(uhrProvider)().toUtc(),
      neueBloecke: bloecke,
    );
    await _schreiben(d, bloecke);
    return d;
  }

  Future<VaultDatei> umbenennen(VaultDatei d, String neuerPfad) async {
    final neu = d.kopie(pfad: _pruefePfad(neuerPfad, d), geaendert: ref.read(uhrProvider)().toUtc());
    await _schreiben(neu, const {});
    return neu;
  }

  Future<void> loeschen(VaultDatei d) async {
    if (nurLesen(d.pfad)) throw VaultFehler('Dieser Ordner ist mit dir nur zum Lesen geteilt.');
    final ablage = ref.read(ablageProvider);
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) async {
          await _stand().loeschen(d.id, tx: tx);
          if (_sitzung.syncAktiv) await SyncStand(ablage, _offen.dek).vormerken(vaultBereich, d.id, tx: tx);
        }));
    await _nachAenderung();
  }

  /// Secret-Treffer einer Datei (`null`: nicht prüfbar, z. B. binär).
  Future<List<SecretTreffer>?> pruefen(VaultDatei d) async => SecretPruefung.standard().pruefen(await inhalt(d));

  /// Erlaubt das Hochladen genau dieses Inhalts trotz Secret-Treffer.
  Future<void> freigeben(VaultDatei d) async {
    final raum = SyncMotor.raumFuerPfad(d.pfad, _offen.bestand.raeume.values);
    await _stand().freigeben(SyncMotor.freigabeSchluessel(d.id, raum?.id), d.sha256);
    unawaited(ref.read(syncProvider.notifier).abgleichen());
  }

  /// Alle Dateien als ZIP (fehlende Blöcke werden dafür geladen).
  /// [fortschritt] bekommt (erledigt, gesamt).
  Future<Uint8List> exportieren({void Function(int, int)? fortschritt}) async {
    final a = Archive();
    final alle = state.dateien;
    for (var i = 0; i < alle.length; i++) {
      final d = alle[i];
      final bytes = await inhalt(d);
      a.addFile(ArchiveFile.bytes(d.pfad, bytes)..lastModTime = d.geaendert.millisecondsSinceEpoch ~/ 1000);
      fortschritt?.call(i + 1, alle.length);
    }
    return Uint8List.fromList(ZipEncoder().encode(a));
  }

  /// Liegt [pfad] in einem geteilten Ordner mit Leserecht?
  bool nurLesen(String pfad) => SyncMotor.raumFuerPfad(pfad, _offen.bestand.raeume.values)?.schreibbar == false;

  String _pruefePfad(String pfad, VaultDatei? alt) {
    final String p;
    try {
      p = vaultPfad(pfad.trim());
    } on FormatException {
      throw VaultFehler('Ungültiger Pfad. Ordner mit „/“ trennen, ohne „..“ und ohne „/“ am Anfang.');
    }
    if (nurLesen(p) || (alt != null && nurLesen(alt.pfad))) throw VaultFehler('Dieser Ordner ist mit dir nur zum Lesen geteilt.');
    final belegt = _anPfad(p);
    if (belegt != null && belegt.id != alt?.id) throw VaultFehler('„$p“ gibt es schon.');
    return p;
  }

  Future<void> _schreiben(VaultDatei d, Map<String, Uint8List> bloecke) async {
    final ablage = ref.read(ablageProvider);
    final stand = _stand();
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) async {
          for (final e in bloecke.entries) {
            await stand.blockSpeichern(e.key, e.value, tx: tx);
          }
          await stand.schreiben(d, tx: tx);
          if (_sitzung.syncAktiv) await SyncStand(ablage, _offen.dek).vormerken(vaultBereich, d.id, tx: tx);
        }));
    await _nachAenderung();
  }

  Future<void> _nachAenderung() async {
    await laden();
    ref.read(syncProvider.notifier).nachAenderung();
  }
}
