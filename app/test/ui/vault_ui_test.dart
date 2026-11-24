import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:personal_tracker/core/krypto/recovery_schluessel.dart';
import 'package:personal_tracker/core/sync/sync_dienst.dart';
import 'package:personal_tracker/core/vault/vault_dienst.dart';

import '../hilfen.dart';
import '../sync_hilfen.dart';
import 'app_test.dart' show appStarten, direktEinrichten, handy, schreibe, tippe;
import 'sync_ui_test.dart' show warteBis;

Uint8List t(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  testWidgets('Vault in der App: Ordner, Markdown bearbeiten, Secret prüfen und freigeben, Grenze', (tester) async {
    final server = TestServer();
    addTearDown(server.speicher.schliessen);
    final a = TestGeraet(name: 'a.db', client: server.client());
    final c = await appStarten(tester, a, groesse: handy);
    final rk = await direktEinrichten(tester, c);

    // Ohne Sync gibt es keinen Vault in der Navigation.
    expect(find.byKey(const Key('nav-vault')), findsNothing);
    await tester.runAsync(() async {
      await c.read(syncProvider.notifier).verbinden(server: TestServer.adresse, recovery: RecoverySchluessel.lesen(rk)!, geraetName: 'Handy');
      final v = c.read(vaultProvider.notifier);
      await v.speichern(pfad: 'Projekte/Hochbeet.md', inhalt: t('# Hochbeet\n\n- [ ] Erde kaufen\n'));
      await v.speichern(pfad: 'Zugang.md', inhalt: t('Router\nPasswort: Pferd-Batterie-77\n'));
      await v.speichern(pfad: '.obsidian/app.json', inhalt: t('{}'));
      await c.read(syncProvider.notifier).abgleichen();
    });
    await tester.pumpAndSettle();

    await tippe(tester, 'nav-vault');
    expect(find.text('Vault.'), findsOneWidget);
    expect(find.byKey(const Key('vault-ordner-Projekte')), findsOneWidget);
    expect(find.byKey(const Key('vault-ordner-.obsidian')), findsNothing);
    await tippe(tester, 'vault-versteckte');
    expect(find.byKey(const Key('vault-ordner-.obsidian')), findsOneWidget);

    // Secret: Hinweis, Prüfen zeigt Regel und Zeile, nie den Wert.
    expect(find.byKey(const Key('vault-pruefen-Zugang.md')), findsOneWidget);
    await tippe(tester, 'vault-pruefen-Zugang.md');
    await warteBis(tester, () => find.textContaining('Passwort- oder Token-Zuweisung in Zeile 2').evaluate().isNotEmpty, grund: 'Treffer');
    await tippe(tester, 'vault-freigeben');
    await tippe(tester, 'bestaetigen-ja');
    await warteBis(tester, () => c.read(syncProvider).vaultGesperrt.isEmpty && !c.read(syncProvider).laeuft, grund: 'freigegeben');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vault-pruefen-Zugang.md')), findsNothing);

    // Markdown im Ordner öffnen, bearbeiten, speichern.
    await tippe(tester, 'vault-ordner-Projekte');
    await tippe(tester, 'vault-datei-Projekte/Hochbeet.md');
    await warteBis(tester, () => find.byKey(const Key('vault-vorschau')).evaluate().isNotEmpty, grund: 'geladen');
    expect(find.text('Hochbeet'), findsWidgets);
    await tester.tap(find.text('Bearbeiten'));
    await tester.pumpAndSettle();
    await schreibe(tester, 'vault-text', '# Hochbeet\n\n- [x] Erde kaufen\n[[Garten]]\n');
    await tippe(tester, 'vault-speichern');
    await warteBis(tester, () => c.read(vaultProvider).dateien.any((d) => d.pfad == 'Projekte/Hochbeet.md' && utf8.decode(d.inhalt!).contains('[[Garten]]')), grund: 'gespeichert');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.runAsync(() => c.read(syncProvider.notifier).abgleichen());
    await tester.pumpAndSettle();
    expect(c.read(syncProvider).ausstehend, 0);
    expect(server.dump(), isNot(contains('Garten')));

    // Suche findet Markdown-Inhalt.
    await schreibe(tester, 'vault-suche', 'garten');
    await warteBis(tester, () => find.byKey(const Key('vault-datei-Projekte/Hochbeet.md')).evaluate().length == 1, grund: 'Suche');

    // Grenze in den Einstellungen.
    await tippe(tester, 'nav-einstellungen');
    expect(find.textContaining('über 100 MiB'), findsOneWidget);
    await tippe(tester, 'vault-grenze-aendern');
    await schreibe(tester, 'vault-grenze-feld', '20');
    await tippe(tester, 'vault-grenze-ok');
    await warteBis(tester, () => find.textContaining('über 20 MiB').evaluate().isNotEmpty, grund: 'Grenze');
  });
}
