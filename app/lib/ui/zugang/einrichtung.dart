
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/krypto/recovery_schluessel.dart';
import '../../core/krypto/schluesselbund.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../sync/sync.dart';
import 'rahmen.dart';
import 'wiederherstellen.dart';

enum _Schritt { willkommen, passwort, recovery, wiederherstellen, syncKoppeln, syncRecovery }

/// Erster Start: neu beginnen (Passwort → Recovery-Schlüssel bestätigen)
/// oder eine Sicherung übernehmen. Gespeichert wird erst nach der
/// Bestätigung des Recovery-Schlüssels.
class EinrichtungSeite extends ConsumerStatefulWidget {
  const EinrichtungSeite({super.key});

  @override
  ConsumerState<EinrichtungSeite> createState() => _EinrichtungSeiteState();
}

class _EinrichtungSeiteState extends ConsumerState<EinrichtungSeite> {
  var _schritt = _Schritt.willkommen;
  final _form = GlobalKey<FormState>();
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  final _kontrolle = TextEditingController();
  bool _arbeitet = false;
  String? _fehler;
  ({Schluesselbund bund, Uint8List dek, RecoverySchluessel recovery})? _vorbereitet;

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    _kontrolle.dispose();
    super.dispose();
  }

  Future<void> _passwortWeiter() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _arbeitet = true);
    final v = await ref.read(sitzungProvider.notifier).einrichtungVorbereiten(_pw1.text);
    if (!mounted) return;
    setState(() {
      _vorbereitet = v;
      _arbeitet = false;
      _schritt = _Schritt.recovery;
    });
  }

  Future<void> _abschliessen() async {
    final v = _vorbereitet!;
    final letzte = v.recovery.anzeigen().split('-').last;
    if (_kontrolle.text.trim().toUpperCase() != letzte) {
      setState(() => _fehler = 'Die letzten vier Zeichen stimmen nicht — bitte vom Zettel abschreiben.');
      return;
    }
    setState(() => _arbeitet = true);
    await ref.read(sitzungProvider.notifier).einrichtungAbschliessen(v.bund, v.dek);
  }

  @override
  Widget build(BuildContext context) {
    return ZugangsRahmen(
      child: switch (_schritt) {
        _Schritt.willkommen => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Seitenkopf(
                oberzeile: 'Erster Start',
                titel: 'Willkommen.',
                unterzeile: 'Termine, Notizen und Haushaltsbuch — verschlüsselt auf diesem Gerät. '
                    'Kein Konto, kein Server, auch dauerhaft offline.',
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('neu-beginnen'),
                onPressed: () => setState(() => _schritt = _Schritt.passwort),
                child: const Text('Neu beginnen'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: const Key('aus-sicherung'),
                onPressed: () => setState(() => _schritt = _Schritt.wiederherstellen),
                child: const Text('Aus einer Sicherung wiederherstellen'),
              ),
              const SizedBox(height: 22),
              Text('Schon mit einem Sync-Server verbunden?', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('mit-geraet-verbinden'),
                onPressed: () => setState(() => _schritt = _Schritt.syncKoppeln),
                child: const Text('Mit einem anderen Gerät verbinden'),
              ),
              const SizedBox(height: 10),
              TextButton(
                key: const Key('aus-sync'),
                onPressed: () => setState(() => _schritt = _Schritt.syncRecovery),
                child: const Text('Alle Geräte verloren? Vom Server wiederherstellen'),
              ),
            ],
          ),
        _Schritt.passwort => Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Seitenkopf(
                  oberzeile: 'Schritt 1 von 2',
                  titel: 'Passwort wählen.',
                  unterzeile: 'Es öffnet die App und verschlüsselt deine Daten. Es wird nirgends gespeichert '
                      'und lässt sich nicht zurücksetzen — dafür gibt es gleich den Recovery-Schlüssel.',
                ),
                const SizedBox(height: 22),
                PasswortFeld(key: const Key('pw1'), controller: _pw1, validator: passwortRegel, autofocus: true),
                const SizedBox(height: 12),
                PasswortFeld(
                  key: const Key('pw2'),
                  controller: _pw2,
                  label: 'Passwort wiederholen',
                  validator: (v) => v != _pw1.text ? 'Die Passwörter sind verschieden.' : null,
                  onSubmitted: (_) => _passwortWeiter(),
                ),
                if (_arbeitet)
                  const Laedt('Schlüssel wird abgeleitet …')
                else ...[
                  const SizedBox(height: 20),
                  FilledButton(key: const Key('pw-weiter'), onPressed: _passwortWeiter, child: const Text('Weiter')),
                  TextButton(onPressed: () => setState(() => _schritt = _Schritt.willkommen), child: const Text('Zurück')),
                ],
              ],
            ),
          ),
        _Schritt.recovery => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Seitenkopf(
                oberzeile: 'Schritt 2 von 2',
                titel: 'Dein Recovery-Schlüssel.',
                unterzeile: 'Schreib ihn auf Papier und bewahre ihn getrennt vom Gerät auf. Er öffnet die App, '
                    'wenn du das Passwort vergisst, und wird für jede Wiederherstellung einer Sicherung gebraucht. '
                    'Er wird nur jetzt angezeigt.',
              ),
              const SizedBox(height: 20),
              RecoveryAnzeige(_vorbereitet!.recovery),
              const Hinweis(
                warnung: true,
                text: 'Ohne Passwort und ohne diesen Schlüssel sind die Daten nicht wiederherstellbar — '
                    'auch nicht durch den Entwickler.',
              ),
              const SizedBox(height: 18),
              TextField(
                key: const Key('rk-kontrolle'),
                controller: _kontrolle,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Kontrolle: letzte 4 Zeichen'),
                onSubmitted: (_) => _abschliessen(),
              ),
              if (_fehler != null) Fehlertext(_fehler!),
              const SizedBox(height: 18),
              if (_arbeitet)
                const Laedt('Wird eingerichtet …')
              else
                FilledButton(
                  key: const Key('einrichtung-fertig'),
                  onPressed: _abschliessen,
                  child: const Text('Aufgeschrieben — los geht’s'),
                ),
            ],
          ),
        _Schritt.syncKoppeln || _Schritt.syncRecovery => SyncAblauf(
            weg: _schritt == _Schritt.syncKoppeln ? SyncWeg.neuKoppeln : SyncWeg.neuRecovery,
            onAbbrechen: () => setState(() => _schritt = _Schritt.willkommen),
          ),
        _Schritt.wiederherstellen => WiederherstellenAblauf(
            neu: true,
            onAbbrechen: () => setState(() => _schritt = _Schritt.willkommen),
          ),
      },
    );
  }
}
