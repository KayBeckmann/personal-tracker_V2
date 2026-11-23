import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/aufgaben/auswahl.dart';
import '../../core/modell/aufgabe.dart';
import '../../core/modell/datum.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import 'aufgabe_formular.dart';

class AufgabenSeite extends ConsumerStatefulWidget {
  const AufgabenSeite({super.key});

  @override
  ConsumerState<AufgabenSeite> createState() => _AufgabenSeiteState();
}

class _AufgabenSeiteState extends ConsumerState<AufgabenSeite> {
  final _suche = TextEditingController();
  bool _erledigteZeigen = false;

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alle = ref.watch(bestandProvider).aufgaben.values;
    final jetzt = DateTime.now();
    final suche = _suche.text.trim().toLowerCase();
    bool passt(Aufgabe a) => suche.isEmpty || '${a.titel} ${a.notiz ?? ''}'.toLowerCase().contains(suche);
    final gruppen = gruppieren(alle.where(passt), jetzt);
    final offen = alle.where((a) => a.offen).length;
    final erledigt = alle.where((a) => !a.offen && passt(a)).toList()..sort((a, b) => b.erledigt!.compareTo(a.erledigt!));
    final keineOffenen = gruppen.values.every((l) => l.isEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: '$offen offen',
          titel: 'Aufgaben.',
          unterzeile: 'Was ansteht, nach Wichtigkeit. Aufgaben werden nie von selbst zu Terminen.',
          aktionen: [
            FilledButton.icon(
              key: const Key('aufgabe-neu'),
              onPressed: () => aufgabeBearbeiten(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Aufgabe'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('aufgabe-suche'),
          controller: _suche,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Aufgaben durchsuchen',
            suffixIcon: suche.isEmpty ? null : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(_suche.clear)),
          ),
        ),
        const SizedBox(height: 18),
        if (keineOffenen)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Karte(
              child: Leer(
                alle.isEmpty
                    ? 'Noch keine Aufgaben. „Aufgabe“ oben legt die erste an — mit Fälligkeit, Wichtigkeit und auf Wunsch wiederkehrend.'
                    : suche.isNotEmpty
                        ? 'Keine offene Aufgabe passt zur Suche.'
                        : 'Alles erledigt.',
              ),
            ),
          ),
        for (final g in Gruppe.values)
          if (gruppen[g]!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Karte(
                key: Key('gruppe-${g.name}'),
                titel: g.titel,
                marke: '${gruppen[g]!.length}',
                markeWarnung: g == Gruppe.ueberfaellig,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, a) in gruppen[g]!.indexed) AufgabenZeile(aufgabe: a, ersteZeile: i == 0, jetzt: jetzt),
                  ],
                ),
              ),
            ),
        if (erledigt.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('erledigte-zeigen'),
              onPressed: () => setState(() => _erledigteZeigen = !_erledigteZeigen),
              icon: Icon(_erledigteZeigen ? Icons.expand_less : Icons.expand_more, size: 18),
              label: Text(_erledigteZeigen ? 'Erledigte ausblenden' : 'Erledigte zeigen (${erledigt.length})'),
            ),
          ),
        if (_erledigteZeigen && erledigt.isNotEmpty)
          Karte(
            key: const Key('gruppe-erledigt'),
            titel: 'Erledigt',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, a) in erledigt.take(50).indexed) AufgabenZeile(aufgabe: a, ersteZeile: i == 0, jetzt: jetzt),
              ],
            ),
          ),
      ],
    );
  }
}

/// Eine Aufgabe mit Abhak-Kreis. Offene werden abgehakt, erledigte wieder
/// geöffnet; Tippen auf die Zeile bearbeitet.
class AufgabenZeile extends ConsumerWidget {
  const AufgabenZeile({super.key, required this.aufgabe, required this.jetzt, this.ersteZeile = false});

  final Aufgabe aufgabe;
  final DateTime jetzt;
  final bool ersteZeile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    final a = aufgabe;
    final ueberfaellig = a.offen && a.faellig != null && a.faellig!.isBefore(tagVon(jetzt));
    return Zeile(
      key: Key('aufgabe-${a.id}'),
      ersteZeile: ersteZeile,
      vorne: SizedBox(
        width: 22,
        height: 22,
        child: IconButton(
          key: Key('abhaken-${a.id}'),
          padding: EdgeInsets.zero,
          iconSize: 20,
          tooltip: a.offen ? 'Abhaken' : 'Wieder öffnen',
          onPressed: () => a.offen ? aufgabeAbhaken(context, ref, a) : ref.read(sitzungProvider.notifier).speichereAufgabe(a.wiedereroeffnen()),
          icon: Icon(a.offen ? Icons.radio_button_unchecked : Icons.check_circle, color: a.offen ? f.meterFuellung : f.leise),
        ),
      ),
      titel: a.titel,
      titelStil: a.offen ? null : TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: f.leise, decoration: TextDecoration.lineThrough),
      unter: aufgabeUnterzeile(a, jetzt),
      rechtsWidget: _Kennzeichen(aufgabe: a, ueberfaellig: ueberfaellig),
      onTap: () => aufgabeBearbeiten(context, ref, aufgabe: a),
    );
  }
}

class _Kennzeichen extends StatelessWidget {
  const _Kennzeichen({required this.aufgabe, required this.ueberfaellig});
  final Aufgabe aufgabe;
  final bool ueberfaellig;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final a = aufgabe;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (a.prioritaet == Prioritaet.hoch)
          Tooltip(message: 'Hohe Wichtigkeit', child: Icon(Icons.flag, size: 15, color: f.warnText)),
        if (a.wiederholung != null) Icon(Icons.repeat, size: 15, color: f.leise),
        if (a.offen && a.erinnerungUm != null) Icon(Icons.notifications_none, size: 15, color: f.leise),
        if (ueberfaellig) ...[const SizedBox(width: 4), const Marke('überfällig', warnung: true)],
      ],
    );
  }
}

/// „Heute · 19:00 · wöchentlich“, „seit Fr, 20. Nov“, „erledigt 23.11.2026“.
String aufgabeUnterzeile(Aufgabe a, DateTime jetzt) {
  if (!a.offen) return 'erledigt ${datumKurz(a.erledigt!.toLocal())}';
  final teile = <String>[];
  final f = a.faellig;
  if (f != null) {
    final heute = tagVon(jetzt);
    final tage = DateTime.utc(f.year, f.month, f.day).difference(DateTime.utc(heute.year, heute.month, heute.day)).inDays;
    teile.add(switch (tage) {
      < 0 => 'fällig seit ${datumMittel(f)}',
      0 => 'Heute',
      1 => 'Morgen',
      < 7 => wochentag(f),
      _ => datumMittel(f),
    });
    if (a.erinnerungUm != null) teile.add(uhrzeitMinuten(a.erinnerungUm!));
  }
  if (a.wiederholung != null) teile.add(a.wiederholung!.beschreibung);
  if (a.prioritaet == Prioritaet.niedrig) teile.add('niedrig');
  if (a.prioritaet == Prioritaet.hoch) teile.add('wichtig');
  return teile.join(' · ');
}

/// Abhaken mit „Rückgängig“; bei Serien steht die nächste Runde dabei.
Future<void> aufgabeAbhaken(BuildContext context, WidgetRef ref, Aufgabe a) async {
  final s = ref.read(sitzungProvider.notifier);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final vorher = await s.aufgabeAbschliessen(a.id);
  if (vorher == null) return;
  final neu = ref.read(bestandProvider).aufgaben[a.id];
  final naechste = neu != null && neu.offen ? neu.faellig : null;
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Text(naechste == null ? '„${a.titel}“ erledigt.' : '„${a.titel}“ erledigt · nächste Runde ${datumMittel(naechste)}'),
    action: SnackBarAction(label: 'Rückgängig', onPressed: () => s.speichereAufgabe(vorher)),
    // Mit Aktion bliebe die Leiste sonst stehen und verdeckte die Liste.
    persist: false,
    duration: const Duration(seconds: 5),
  ));
}
