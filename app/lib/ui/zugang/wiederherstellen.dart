import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/krypto/recovery_schluessel.dart';
import '../../core/modell/bestand.dart';
import '../../core/sitzung.dart';
import '../../core/speicher/backup.dart';
import '../bausteine.dart';
import '../dateien.dart';
import '../format.dart';
import 'rahmen.dart';

/// Sicherung einlesen: Datei → Recovery-Schlüssel → Vorschau → übernehmen.
/// [neu]: frische Installation (neues Passwort). Sonst ersetzt sie die
/// aktuellen Daten nach ausdrücklicher Bestätigung.
class WiederherstellenAblauf extends ConsumerStatefulWidget {
  const WiederherstellenAblauf({super.key, required this.neu, required this.onAbbrechen, this.onFertig, this.vorherSichern});

  final bool neu;
  final VoidCallback onAbbrechen;
  final VoidCallback? onFertig;

  /// Bietet vor dem Ersetzen an, den aktuellen Stand zu sichern.
  final Future<void> Function()? vorherSichern;

  @override
  ConsumerState<WiederherstellenAblauf> createState() => _WiederherstellenAblaufState();
}

class _WiederherstellenAblaufState extends ConsumerState<WiederherstellenAblauf> {
  final _rk = TextEditingController();
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  final _form = GlobalKey<FormState>();
  ({String name, Uint8List bytes})? _datei;
  BackupKopf? _kopf;
  ({BackupInhalt inhalt, Bestand bestand})? _geprueft;
  RecoverySchluessel? _schluessel;
  String? _fehler;
  bool _arbeitet = false;

  @override
  void dispose() {
    _rk.dispose();
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _dateiWaehlen() async {
    final d = await ref.read(dateienProvider).oeffnen();
    if (d == null || !mounted) return;
    setState(() {
      _fehler = null;
      _geprueft = null;
      try {
        _kopf = Backup.kopfLesen(d.bytes);
        _datei = d;
      } on BackupFehler catch (e) {
        _kopf = null;
        _datei = null;
        _fehler = e.meldung;
      }
    });
  }

  void _pruefen() {
    final r = RecoverySchluessel.lesen(_rk.text);
    setState(() {
      _fehler = null;
      if (r == null) {
        _fehler = 'Der Recovery-Schlüssel hat 32 Zeichen (8 Gruppen à 4).';
        return;
      }
      try {
        _geprueft = SitzungNotifier.sicherungPruefen(_datei!.bytes, r);
        _schluessel = r;
      } on BackupFehler catch (e) {
        _fehler = e.meldung;
      }
    });
  }

  Future<void> _uebernehmen() async {
    final g = _geprueft!;
    final s = ref.read(sitzungProvider.notifier);
    if (widget.neu) {
      if (!_form.currentState!.validate()) return;
      setState(() => _arbeitet = true);
      await s.wiederherstellenNeu(g.bestand, _schluessel!, _pw1.text);
    } else {
      final ok = await bestaetigen(
        context,
        titel: 'Alle Daten ersetzen?',
        text: 'Termine, Aufgaben, Notizen und Haushaltsbuch auf diesem Gerät werden durch die Sicherung vom '
            '${datumKurz(g.inhalt.kopf.erstellt.toLocal())} ersetzt. Das lässt sich nicht rückgängig machen. '
            'Dein Passwort bleibt; künftig gilt der Recovery-Schlüssel dieser Sicherung.',
        ja: 'Ersetzen',
      );
      if (!ok) return;
      setState(() => _arbeitet = true);
      await s.wiederherstellenErsetzen(g.bestand, _schluessel!);
    }
    widget.onFertig?.call();
  }

  @override
  Widget build(BuildContext context) {
    final g = _geprueft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: 'Wiederherstellen',
          titel: 'Sicherung einlesen.',
          unterzeile: widget.neu
              ? 'Wähle die Sicherungsdatei (.${Backup.dateiendung}) und gib den Recovery-Schlüssel ein, '
                  'der zu ihr gehört.'
              : 'Ersetzt alle Daten auf diesem Gerät durch den Stand der Sicherung — erst nach Vorschau und Bestätigung.',
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          key: const Key('sicherung-waehlen'),
          onPressed: _arbeitet ? null : _dateiWaehlen,
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: Text(_datei == null ? 'Sicherungsdatei wählen' : _datei!.name, overflow: TextOverflow.ellipsis),
        ),
        if (_kopf != null) ...[
          const SizedBox(height: 8),
          Text(
            'Sicherung vom ${datumKurz(_kopf!.erstellt.toLocal())}, ${uhrzeit(_kopf!.erstellt.toLocal())} Uhr',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
        if (_kopf != null && g == null) ...[
          const SizedBox(height: 14),
          TextField(
            key: const Key('rk-eingabe'),
            controller: _rk,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Recovery-Schlüssel', hintText: 'XXXX-XXXX-…'),
            onSubmitted: (_) => _pruefen(),
          ),
          const SizedBox(height: 12),
          FilledButton(key: const Key('sicherung-pruefen'), onPressed: _pruefen, child: const Text('Prüfen')),
        ],
        if (_fehler != null) Fehlertext(_fehler!),
        if (g != null) ...[
          const SizedBox(height: 16),
          Karte(
            titel: 'Inhalt der Sicherung',
            child: Column(
              key: const Key('sicherung-vorschau'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (name, anzahl) in [
                  ('Termine', g.bestand.termine.length),
                  ('Aufgaben', g.bestand.aufgaben.length),
                  ('Notizen', g.bestand.notizen.length),
                  ('Konten', g.bestand.konten.length),
                  ('Buchungen', g.bestand.buchungen.length),
                  ('Wiederkehrende Posten', g.bestand.plaene.length),
                ])
                  Zeile(titel: name, rechts: '$anzahl', ersteZeile: name == 'Termine'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (widget.neu)
            Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Neues Passwort für dieses Gerät:'),
                  const SizedBox(height: 10),
                  PasswortFeld(key: const Key('pw1'), controller: _pw1, validator: passwortRegel),
                  const SizedBox(height: 12),
                  PasswortFeld(
                    key: const Key('pw2'),
                    controller: _pw2,
                    label: 'Passwort wiederholen',
                    validator: (v) => v != _pw1.text ? 'Die Passwörter sind verschieden.' : null,
                  ),
                ],
              ),
            )
          else if (widget.vorherSichern != null)
            OutlinedButton.icon(
              onPressed: _arbeitet ? null : widget.vorherSichern,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Vorher aktuellen Stand sichern'),
            ),
          const SizedBox(height: 16),
          if (_arbeitet)
            const Laedt('Wird übernommen …')
          else
            FilledButton(
              key: const Key('sicherung-uebernehmen'),
              onPressed: _uebernehmen,
              child: Text(widget.neu ? 'Wiederherstellen' : 'Alle Daten ersetzen …'),
            ),
        ],
        const SizedBox(height: 4),
        if (!_arbeitet) TextButton(onPressed: widget.onAbbrechen, child: const Text('Abbrechen')),
      ],
    );
  }
}
