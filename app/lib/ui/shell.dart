import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dienste/erinnerungen.dart';
import '../core/sitzung.dart';
import '../core/sync/sync_dienst.dart';
import '../core/vault/vault_dienst.dart';
import 'aufgaben/aufgaben.dart';
import 'einkauf/einkauf.dart';
import 'einstellungen/einstellungen.dart';
import 'finanzen/haushaltsbuch.dart';
import 'navigation.dart';
import 'notizen/notizen.dart';
import 'termine/termine.dart';
import 'raeume/freigaben.dart';
import 'vault/vault.dart';
import 'thema.dart';
import 'sync/sync.dart';
import 'uebersicht/uebersicht.dart';
import 'zugang/rahmen.dart';

/// Rahmen nach Mock-up 01: breite Ansicht mit Seitenleiste in einer
/// abgerundeten Fläche, schmale Ansicht mit waagerechter Navigation.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  static const breitAb = 820.0;

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  StreamSubscription<String>? _webHinweise;

  @override
  void initState() {
    super.initState();
    final e = ref.read(erinnerungenProvider);
    if (e is WebErinnerungen) {
      _webHinweise = e.hinweise.listen((t) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text('Erinnerung: $t'),
            duration: const Duration(seconds: 12),
          ));
        }
      });
    }
  }

  @override
  void dispose() {
    _webHinweise?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bereich = ref.watch(bereichProvider);
    final f = context.farben;
    final inhalt = switch (bereich) {
      Bereich.uebersicht => const UebersichtSeite(),
      Bereich.termine => const TermineSeite(),
      Bereich.aufgaben => const AufgabenSeite(),
      Bereich.notizen => const NotizenSeite(),
      Bereich.finanzen => const HaushaltsbuchSeite(),
      Bereich.einkauf => const EinkaufSeite(),
      Bereich.vault => const VaultSeite(),
      Bereich.freigaben => const FreigabenSeite(),
      Bereich.einstellungen => const EinstellungenSeite(),
    };

    return LayoutBuilder(builder: (context, c) {
      final breit = c.maxWidth >= Shell.breitAb;
      if (!breit) {
        return Scaffold(
          backgroundColor: f.flaeche,
          body: SafeArea(
            child: Column(
              children: [
                _SchmaleLeiste(aktiv: bereich),
                Expanded(
                  child: SingleChildScrollView(
                    key: PageStorageKey('inhalt-${bereich.name}'),
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 80),
                    child: inhalt,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        backgroundColor: f.hintergrund,
        body: SafeArea(
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 1180),
              margin: EdgeInsets.symmetric(vertical: c.maxHeight > 700 ? 28 : 12, horizontal: 20),
              decoration: BoxDecoration(
                color: f.flaeche,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [BoxShadow(color: f.schatten, blurRadius: 70, offset: const Offset(0, 24))],
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Seitenleiste(aktiv: bereich),
                  Expanded(
                    child: SingleChildScrollView(
                      key: PageStorageKey('inhalt-${bereich.name}'),
                      padding: const EdgeInsets.fromLTRB(52, 36, 52, 45),
                      child: inhalt,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

String _markenUnter(WidgetRef ref) => ref.watch(syncProvider).verbunden ? 'V2 · SYNC' : 'V2 · LOKAL';

List<Bereich> _bereiche(WidgetRef ref) =>
    sichtbareBereiche(
      vault: ref.watch(syncProvider).verbunden || !ref.watch(vaultProvider).leer,
      freigaben: ref.watch(syncProvider).verbunden || ref.watch(bestandProvider).raeume.isNotEmpty,
    );

class _Seitenleiste extends ConsumerWidget {
  const _Seitenleiste({required this.aktiv});
  final Bereich aktiv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    return Container(
      width: 224,
      decoration: BoxDecoration(color: f.seite, border: Border(right: BorderSide(color: f.seiteRand))),
      padding: const EdgeInsets.fromLTRB(20, 34, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 30), child: Markenzeichen(unter: _markenUnter(ref))),
          // Scrollbar, damit niedrige Fenster nicht überlaufen.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final b in _bereiche(ref))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _NavKnopf(bereich: b, aktiv: b == aktiv),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SyncStatusText(style: TextStyle(fontSize: 12, color: f.leise, height: 1.5)),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('sperren'),
              onPressed: () => ref.read(sitzungProvider.notifier).sperren(),
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('Sperren'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavKnopf extends ConsumerWidget {
  const _NavKnopf({required this.bereich, required this.aktiv, this.kompakt = false});
  final Bereich bereich;
  final bool aktiv;
  final bool kompakt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    return Material(
      color: aktiv ? f.navAktiv : Colors.transparent,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        key: Key('nav-${bereich.name}'),
        borderRadius: BorderRadius.circular(13),
        onTap: () => ref.read(bereichProvider.notifier).gehe(bereich),
        child: Padding(
          padding: kompakt ? const EdgeInsets.symmetric(horizontal: 12, vertical: 7) : const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisSize: kompakt ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(bereich.icon, size: 17, color: aktiv ? f.navAktivText : f.gedaempft),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  bereich.titel,
                  style: TextStyle(color: aktiv ? f.navAktivText : f.gedaempft, fontWeight: aktiv ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SchmaleLeiste extends ConsumerWidget {
  const _SchmaleLeiste({required this.aktiv});
  final Bereich aktiv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    return Container(
      decoration: BoxDecoration(color: f.seite, border: Border(bottom: BorderSide(color: f.seiteRand))),
      padding: const EdgeInsets.fromLTRB(18, 13, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Markenzeichen(unter: _markenUnter(ref))),
              IconButton(
                key: const Key('sperren'),
                tooltip: 'Sperren',
                onPressed: () => ref.read(sitzungProvider.notifier).sperren(),
                icon: Icon(Icons.lock_outline, color: f.gedaempft),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final b in _bereiche(ref))
                  Padding(padding: const EdgeInsets.only(right: 4), child: _NavKnopf(bereich: b, aktiv: b == aktiv, kompakt: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
