import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/krypto/recovery_schluessel.dart';
import '../../core/sitzung.dart';
import '../../core/speicher/schema.dart';
import '../bausteine.dart';
import '../thema.dart';
import 'rahmen.dart';

class EntsperrenSeite extends ConsumerStatefulWidget {
  const EntsperrenSeite({super.key});

  @override
  ConsumerState<EntsperrenSeite> createState() => _EntsperrenSeiteState();
}

class _EntsperrenSeiteState extends ConsumerState<EntsperrenSeite> {
  final _pw = TextEditingController();
  final _rk = TextEditingController();
  bool _arbeitet = false;
  bool _recovery = false;
  String? _fehler;

  bool get _biometrie {
    final s = ref.read(sitzungProvider);
    return s is Gesperrt && s.bund.biometrie && ref.read(biometrieProvider).unterstuetzt;
  }

  @override
  void initState() {
    super.initState();
    // Fingerabdruck direkt anbieten.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _biometrie) _mitBiometrie();
    });
  }

  @override
  void dispose() {
    _pw.dispose();
    _rk.dispose();
    super.dispose();
  }

  Future<void> _versuch(Future<bool> Function() aktion, String fehler) async {
    setState(() {
      _arbeitet = true;
      _fehler = null;
    });
    try {
      final ok = await aktion();
      if (!ok && mounted) setState(() => _fehler = fehler);
    } on SchemaFehler catch (e) {
      if (mounted) setState(() => _fehler = e.meldung);
    } catch (e) {
      if (mounted) setState(() => _fehler = 'Die Daten ließen sich nicht öffnen: $e');
    } finally {
      if (mounted) setState(() => _arbeitet = false);
    }
  }

  Future<void> _mitPasswort() =>
      _versuch(() => ref.read(sitzungProvider.notifier).entsperren(_pw.text), 'Das Passwort stimmt nicht.');

  Future<void> _mitBiometrie() => _versuch(
        () => ref.read(sitzungProvider.notifier).entsperrenMitBiometrie(),
        'Fingerabdruck nicht bestätigt — bitte das Passwort verwenden.',
      );

  Future<void> _mitRecovery() {
    final r = RecoverySchluessel.lesen(_rk.text);
    if (r == null) {
      setState(() => _fehler = 'Der Recovery-Schlüssel hat 32 Zeichen (8 Gruppen à 4).');
      return Future.value();
    }
    return _versuch(() => ref.read(sitzungProvider.notifier).entsperrenMitRecovery(r), 'Dieser Recovery-Schlüssel passt nicht.');
  }

  Future<void> _zuruecksetzen() async {
    final ok = await eingabeDialog<bool>(
      context,
      builder: (ctx, felder) => AlertDialog(
        title: const Text('Alles löschen?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Alle Termine, Notizen und Buchungen auf diesem Gerät werden endgültig gelöscht. '
                'Eine vorhandene Sicherung lässt sich danach mit ihrem Recovery-Schlüssel wieder einlesen.'),
            const SizedBox(height: 14),
            TextField(
              key: const Key('loeschen-eingabe'),
              controller: felder[0],
              decoration: const InputDecoration(labelText: 'Zur Bestätigung LÖSCHEN eingeben'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(
            key: const Key('loeschen-ja'),
            style: FilledButton.styleFrom(backgroundColor: ctx.farben.fehler),
            onPressed: () => Navigator.pop(ctx, felder[0].text.trim().toUpperCase() == 'LÖSCHEN'),
            child: const Text('Endgültig löschen'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(sitzungProvider.notifier).zuruecksetzen();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sitzungProvider);
    return ZugangsRahmen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Seitenkopf(
            oberzeile: 'Gesperrt',
            titel: _recovery ? 'Mit Recovery-Schlüssel öffnen.' : 'Willkommen zurück.',
            unterzeile: _recovery
                ? 'Danach legst du ein neues Passwort fest.'
                : 'Deine Daten sind verschlüsselt auf diesem Gerät.',
          ),
          const SizedBox(height: 22),
          if (!_recovery) ...[
            PasswortFeld(key: const Key('entsperren-pw'), controller: _pw, autofocus: !_biometrie, onSubmitted: (_) => _mitPasswort()),
            const SizedBox(height: 14),
            FilledButton(key: const Key('entsperren'), onPressed: _arbeitet ? null : _mitPasswort, child: const Text('Entsperren')),
            if (_biometrie) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('fingerabdruck'),
                onPressed: _arbeitet ? null : _mitBiometrie,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Mit Fingerabdruck'),
              ),
            ],
          ] else ...[
            TextField(
              key: const Key('rk-entsperren'),
              controller: _rk,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Recovery-Schlüssel', hintText: 'XXXX-XXXX-…'),
              onSubmitted: (_) => _mitRecovery(),
            ),
            const SizedBox(height: 14),
            FilledButton(key: const Key('rk-oeffnen'), onPressed: _arbeitet ? null : _mitRecovery, child: const Text('Öffnen')),
          ],
          if (_arbeitet) const Laedt('Wird entschlüsselt …'),
          if (_fehler != null) Fehlertext(_fehler!),
          if (s is Gesperrt && s.fehler != null) Fehlertext(s.fehler!),
          const SizedBox(height: 10),
          TextButton(
            key: const Key('recovery-umschalten'),
            onPressed: () => setState(() {
              _recovery = !_recovery;
              _fehler = null;
            }),
            child: Text(_recovery ? 'Doch mit Passwort' : 'Passwort vergessen?'),
          ),
          if (_recovery)
            TextButton(
              key: const Key('alles-loeschen'),
              onPressed: _zuruecksetzen,
              style: TextButton.styleFrom(foregroundColor: context.farben.fehler),
              child: const Text('Weder Passwort noch Schlüssel? Alles löschen …'),
            ),
        ],
      ),
    );
  }
}
