import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../krypto/krypto.dart';
import '../sitzung.dart';
import '../sync/sync_api.dart';
import '../sync/sync_dienst.dart';
import '../sync/sync_stand.dart';
import '../vault/vault_datei.dart';
import '../vault/vault_stand.dart';
import 'raum.dart';

final raumDienstProvider = Provider<RaumDienst>(RaumDienst.new);

class RaumFehler implements Exception {
  RaumFehler(this.meldung);
  final String meldung;
  @override
  String toString() => meldung;
}

/// Freigaben verwalten (siehe `protokoll/RAEUME.md`). Alles hier braucht
/// eine Verbindung zum Server; Inhalte gleicht danach der normale Sync ab.
class RaumDienst {
  RaumDienst(this.ref);
  final Ref ref;

  static const einladungGueltig = Duration(days: 7);

  SitzungNotifier get _sitzung => ref.read(sitzungProvider.notifier);
  SyncNotifier get _sync => ref.read(syncProvider.notifier);

  Entsperrt get _offen {
    final s = ref.read(sitzungProvider);
    if (s is! Entsperrt) throw StateError('Nicht entsperrt');
    return s;
  }

  /// Name, unter dem andere mich sehen.
  String get meinName {
    final n = _offen.bestand.einstellungen.anzeigeName?.trim();
    return n == null || n.isEmpty ? 'Ohne Namen' : n;
  }

  Future<void> _speichern(Raum r) => _sitzung.raumSpeichern(r);

  /// Neue Freigabe. Vault: [ordner] wird geteilt, mit allem darunter.
  Future<Raum> anlegen({required RaumArt art, required String name, String? ordner}) async {
    if (!_sitzung.syncAktiv) throw RaumFehler('Freigaben brauchen eine Sync-Verbindung.');
    String? o;
    if (art == RaumArt.vault) {
      try {
        o = vaultPfad((ordner ?? '').trim());
      } on FormatException {
        throw RaumFehler('Bitte einen gültigen Ordner im Vault angeben.');
      }
      for (final r in _offen.bestand.raeume.values) {
        final x = r.ordner;
        if (x != null && (x == o || x.startsWith('$o/') || o.startsWith('$x/'))) {
          throw RaumFehler('„$x“ ist schon Teil der Freigabe „${r.name}“. Ordnerfreigaben dürfen sich nicht überschneiden.');
        }
      }
    }
    final (_, api) = await _sync.werkzeug();
    final r = Raum(
      id: hex(zufall(16)),
      art: art,
      name: name.trim().isEmpty ? art.titel : name.trim(),
      recht: 'eigentuemer',
      von: meinName,
      idSchluessel: zufall(32),
      schluessel: {1: zufall(32)},
      epoche: 1,
      ordner: o,
    );
    await api.raumAnlegen(r.id);
    await _speichern(r);
    if (o != null) await _vaultUnterOrdnerVormerken(o);
    unawaited(_sync.abgleichen());
    return r;
  }

  /// Alle Vault-Dateien unter [ordner] erneut senden (sie wechseln den Ort).
  Future<void> _vaultUnterOrdnerVormerken(String ordner) async {
    final ablage = ref.read(ablageProvider);
    final dek = _offen.dek;
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) async {
          for (final d in await VaultStand(ablage, dek).alle(tx: tx)) {
            if (d.pfad.startsWith('$ordner/')) await SyncStand(ablage, dek).vormerken(vaultBereich, d.id, tx: tx);
          }
        }));
  }

  /// Einladungscode für eine Person (persönlich weitergeben).
  Future<({Einladungscode code, DateTime bis})> einladen(Raum r, String recht) async {
    if (!r.eigen) throw RaumFehler('Nur wer die Freigabe angelegt hat, kann einladen.');
    final (_, api) = await _sync.werkzeug();
    final code = Einladungscode.neu();
    await api.einladungAnlegen(
      r.id,
      slot: code.slot,
      recht: recht,
      paket: code.paket(r, meinName),
      mitgliedPaket: r.mitgliedPaket(code.paar),
      gueltig: einladungGueltig,
    );
    final bis = ref.read(uhrProvider)().add(einladungGueltig);
    await _speichern(r.kopie(einladungen: [...r.einladungen, (slot: code.slot, paar: code.paar, recht: recht, bis: bis)]));
    return (code: code, bis: bis);
  }

  /// Einladung annehmen. Bei einem Vault-Ordner bestimmt [ordner], wo er
  /// in meinem Vault erscheint.
  Future<Raum> annehmen(String codeText, {String? ordner}) async {
    final code = Einladungscode.lesen(codeText);
    if (code == null) throw RaumFehler('Der Einladungscode hat 20 Zeichen (Buchstaben und Ziffern).');
    if (!_sitzung.syncAktiv) throw RaumFehler('Zum Annehmen braucht die App eine Sync-Verbindung.');
    final (_, api) = await _sync.werkzeug();
    final ({String raum, String recht, String paket}) e;
    try {
      e = await api.einladungAnnehmen(code.slot, Raum.antwort(code.slot, code.paar, meinName));
    } on SyncFehler catch (f) {
      if (f.art == SyncFehlerArt.nichtGefunden) throw RaumFehler('Einladung unbekannt, abgelaufen oder schon benutzt.');
      if (f.art == SyncFehlerArt.vorhanden) throw RaumFehler('Du gehörst schon zu dieser Freigabe.');
      rethrow;
    }
    final p = code.paketOeffnen(e.paket);
    final eintrag = (await api.raeume()).where((x) => x['id'] == e.raum).firstOrNull;
    final k = eintrag == null || p == null ? null : Raum.mitgliedPaketOeffnen(e.raum, code.paar, eintrag['paket'] as String);
    if (p == null || p.raum != e.raum || k == null) {
      await api.raumVerlassen(e.raum);
      throw RaumFehler('Die Einladung ließ sich nicht prüfen und wurde verworfen. Bitte einen neuen Code geben lassen.');
    }
    String? o;
    if (p.art == RaumArt.vault) {
      final wunsch = (ordner == null || ordner.trim().isEmpty) ? 'Geteilt/${p.name.replaceAll('/', '-')}' : ordner.trim();
      try {
        o = vaultPfad(wunsch);
      } on FormatException {
        throw RaumFehler('Ungültiger Ordner.');
      }
    }
    final r = Raum(
      id: e.raum,
      art: p.art,
      name: p.name,
      recht: e.recht,
      von: p.von,
      idSchluessel: p.idSchluessel,
      schluessel: k.schluessel,
      epoche: k.epoche,
      paar: code.paar,
      ordner: o,
    );
    await _speichern(r);
    await _sync.abgleichen();
    return r;
  }

  Future<void> rechtAendern(Raum r, Mitglied m, String recht) async {
    final (motor, api) = await _sync.werkzeug();
    await api.mitgliedAendern(r.id, m.konto, recht: recht);
    final neu = r.kopie(mitglieder: [for (final x in r.mitglieder) x.konto == m.konto ? x.mit(recht: recht) : x]);
    await _speichern(neu);
    await motor.infoSenden(neu);
  }

  /// Mitglied entfernen: Der Server liefert ihm sofort nichts mehr, und
  /// ein neuer Raumschlüssel gilt für alles Weitere. Was das Mitglied
  /// schon hat, lässt sich nicht zurückholen.
  Future<void> entfernen(Raum r, Mitglied m) async {
    final (motor, api) = await _sync.werkzeug();
    await api.mitgliedEntfernen(r.id, m.konto);
    final epoche = r.epoche + 1;
    final neu = r.kopie(
      mitglieder: [for (final x in r.mitglieder) if (x.konto != m.konto) x],
      schluessel: {...r.schluessel, epoche: zufall(32)},
      epoche: epoche,
    );
    for (final x in neu.mitglieder) {
      await api.mitgliedAendern(r.id, x.konto, paket: neu.mitgliedPaket(x.paar));
    }
    await _speichern(neu);
    await motor.infoSenden(neu);
  }

  /// Mitglied: austreten (die geteilten Inhalte verschwinden hier).
  /// Eigentümer: die Freigabe beenden (alles wird wieder privat).
  Future<void> verlassen(Raum r) async {
    final (motor, api) = await _sync.werkzeug();
    final ablage = ref.read(ablageProvider);
    await api.raumVerlassen(r.id);
    await _sitzung.sperre.exklusiv(() => ablage.transaktion((tx) => motor.raumEntfernen(r, tx)));
    await _sitzung.neuLaden();
    unawaited(_sync.abgleichen());
  }
}
