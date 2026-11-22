import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sitzung.dart';
import '../bausteine.dart';
import 'rahmen.dart';

/// Nach Entsperren per Recovery-Schlüssel: neues Passwort festlegen.
class NeuesPasswortSeite extends ConsumerStatefulWidget {
  const NeuesPasswortSeite({super.key});

  @override
  ConsumerState<NeuesPasswortSeite> createState() => _NeuesPasswortSeiteState();
}

class _NeuesPasswortSeiteState extends ConsumerState<NeuesPasswortSeite> {
  final _form = GlobalKey<FormState>();
  final _pw1 = TextEditingController();
  final _pw2 = TextEditingController();
  bool _arbeitet = false;

  @override
  void dispose() {
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _speichern() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _arbeitet = true);
    await ref.read(sitzungProvider.notifier).neuesPasswort(_pw1.text);
  }

  @override
  Widget build(BuildContext context) => ZugangsRahmen(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Seitenkopf(
                oberzeile: 'Recovery-Schlüssel akzeptiert',
                titel: 'Neues Passwort.',
                unterzeile: 'Deine Daten sind unverändert. Der Recovery-Schlüssel bleibt gültig.',
              ),
              const SizedBox(height: 22),
              PasswortFeld(key: const Key('pw1'), controller: _pw1, validator: passwortRegel, autofocus: true),
              const SizedBox(height: 12),
              PasswortFeld(
                key: const Key('pw2'),
                controller: _pw2,
                label: 'Passwort wiederholen',
                validator: (v) => v != _pw1.text ? 'Die Passwörter sind verschieden.' : null,
                onSubmitted: (_) => _speichern(),
              ),
              const SizedBox(height: 20),
              if (_arbeitet)
                const Laedt('Wird gespeichert …')
              else
                FilledButton(key: const Key('pw-speichern'), onPressed: _speichern, child: const Text('Speichern')),
            ],
          ),
        ),
      );
}
