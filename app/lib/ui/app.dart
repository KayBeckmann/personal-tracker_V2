import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sitzung.dart';
import '../core/sync/sync_dienst.dart';
import 'navigation.dart';
import 'shell.dart';
import 'thema.dart';
import 'zugang/einrichtung.dart';
import 'zugang/entsperren.dart';
import 'zugang/neues_passwort.dart';

class TrackerApp extends ConsumerStatefulWidget {
  const TrackerApp({super.key, this.sperrenNach = const Duration(minutes: 5)});

  /// Im Hintergrund länger als das → beim Zurückkehren gesperrt.
  final Duration sperrenNach;

  @override
  ConsumerState<TrackerApp> createState() => _TrackerAppState();
}

class _TrackerAppState extends ConsumerState<TrackerApp> {
  late final AppLifecycleListener _lebenszyklus;
  final _navigator = GlobalKey<NavigatorState>();
  DateTime? _weg;

  @override
  void initState() {
    super.initState();
    _lebenszyklus = AppLifecycleListener(
      onHide: () => _weg ??= DateTime.now(),
      onShow: () {
        final weg = _weg;
        _weg = null;
        if (weg != null && DateTime.now().difference(weg) >= widget.sperrenNach) {
          ref.read(sitzungProvider.notifier).sperren();
        }
      },
    );
  }

  @override
  void dispose() {
    _lebenszyklus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Beim Sperren offene Seiten und Dialoge schließen, damit keine Daten
    // über dem Sperrbildschirm stehen bleiben.
    ref.listen(sitzungProvider, (vorher, jetzt) {
      if (vorher is Entsperrt && jetzt is! Entsperrt) {
        _navigator.currentState?.popUntil((r) => r.isFirst);
      }
    });
    // Hält den Sync-Dienst von Anfang an am Leben, damit er das
    // Entsperren mitbekommt.
    ref.listen(syncProvider, (_, _) {});
    final sitzung = ref.watch(sitzungProvider);
    final Widget seite = switch (sitzung) {
      Einrichtung() => const EinrichtungSeite(),
      Gesperrt() => const EntsperrenSeite(),
      Entsperrt(neuesPasswortNoetig: true) => const NeuesPasswortSeite(),
      Entsperrt() => const Shell(),
    };
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Personal Tracker',
      debugShowCheckedModeBanner: false,
      theme: trackerThema(Brightness.light),
      darkTheme: trackerThema(Brightness.dark),
      themeMode: ref.watch(farbschemaProvider),
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(key: ValueKey(sitzung.runtimeType), child: seite),
      ),
    );
  }
}
