import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sitzung.dart';

enum Bereich {
  uebersicht('Übersicht', Icons.radio_button_checked),
  termine('Termine', Icons.calendar_today_outlined),
  aufgaben('Aufgaben', Icons.task_alt),
  notizen('Notizen', Icons.notes_outlined),
  finanzen('Haushaltsbuch', Icons.account_balance_wallet_outlined),
  vault('Vault', Icons.folder_open_outlined),
  freigaben('Freigaben', Icons.group_outlined),
  einstellungen('Speicher & Sicherheit', Icons.lock_outline);

  const Bereich(this.titel, this.icon);
  final String titel;
  final IconData icon;
}

class BereichNotifier extends Notifier<Bereich> {
  @override
  Bereich build() => Bereich.uebersicht;
  void gehe(Bereich b) => state = b;
}

final bereichProvider = NotifierProvider<BereichNotifier, Bereich>(BereichNotifier.new);

/// Bereiche in der Navigation; den Vault gibt es nur mit Sync (oder wenn
/// schon Vault-Dateien da sind).
List<Bereich> sichtbareBereiche({required bool vault, bool freigaben = false}) =>
    [for (final b in Bereich.values) if ((b != Bereich.vault || vault) && (b != Bereich.freigaben || freigaben)) b];

/// Beim Start gelesenes Farbschema (liegt unverschlüsselt, damit schon
/// der Entsperrbildschirm passt).
final startFarbschemaProvider = Provider<ThemeMode>((ref) => ThemeMode.system);

class FarbschemaNotifier extends Notifier<ThemeMode> {
  static const meta = 'farbschema';

  @override
  ThemeMode build() => ref.read(startFarbschemaProvider);

  Future<void> setzen(ThemeMode m) async {
    state = m;
    await ref.read(ablageProvider).setzeMeta(meta, m.name);
  }
}

final farbschemaProvider = NotifierProvider<FarbschemaNotifier, ThemeMode>(FarbschemaNotifier.new);
