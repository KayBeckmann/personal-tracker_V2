import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kalender/vorkommen.dart';
import '../../core/modell/datum.dart';
import '../../core/modell/termin.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import 'termin_formular.dart';

class TermineSeite extends ConsumerStatefulWidget {
  const TermineSeite({super.key});

  @override
  ConsumerState<TermineSeite> createState() => _TermineSeiteState();
}

class _TermineSeiteState extends ConsumerState<TermineSeite> {
  late DateTime _tag = tagVon(DateTime.now());
  late Monat _monat = monatVon(_tag);
  final _suche = TextEditingController();

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  void _waehle(DateTime tag) => setState(() {
        _tag = tagVon(tag);
        _monat = monatVon(tag);
      });

  @override
  Widget build(BuildContext context) {
    final bestand = ref.watch(bestandProvider);
    final termine = bestand.termine.values;
    final ersterImRaster = () {
      final erster = monatsErster(_monat);
      return erster.subtract(Duration(days: erster.weekday - 1));
    }();
    final letzterImRaster = DateTime(ersterImRaster.year, ersterImRaster.month, ersterImRaster.day + 41);
    final imRaster = alleVorkommen(termine, ersterImRaster, letzterImRaster);
    final tageMitTermin = <String>{
      for (final v in imRaster)
        for (var d = tagVon(v.beginn); !d.isAfter(v.letzterTag); d = DateTime(d.year, d.month, d.day + 1)) tagIso(d),
    };
    final amTag = alleVorkommen(termine, _tag, _tag);
    final suche = _suche.text.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: monatName(monatVon(DateTime.now())),
          titel: 'Termine.',
          unterzeile: 'Einmalig oder wiederkehrend — mit Erinnerung, wenn du willst.',
          aktionen: [
            FilledButton.icon(
              key: const Key('termin-neu'),
              onPressed: () => terminBearbeiten(context, ref, tag: _tag),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Termin'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('termin-suche'),
          controller: _suche,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Termine durchsuchen',
            suffixIcon: suche.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(_suche.clear)),
          ),
        ),
        const SizedBox(height: 18),
        if (suche.isNotEmpty)
          _Suchergebnis(suche: suche, termine: termine, onWahl: (d) {
            _suche.clear();
            _waehle(d);
          })
        else
          Raster(
            verhaeltnis: 1.25,
            kinder: [
              Karte(
                titel: monatName(_monat),
                aktion: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(key: const Key('monat-zurueck'), tooltip: 'Voriger Monat', onPressed: () => setState(() => _monat--), icon: const Icon(Icons.chevron_left)),
                    TextButton(onPressed: () => _waehle(DateTime.now()), child: const Text('Heute')),
                    IconButton(key: const Key('monat-vor'), tooltip: 'Nächster Monat', onPressed: () => setState(() => _monat++), icon: const Icon(Icons.chevron_right)),
                  ],
                ),
                child: _Monatsraster(
                  monat: _monat,
                  erster: ersterImRaster,
                  gewaehlt: _tag,
                  mitTermin: tageMitTermin,
                  onWahl: _waehle,
                ),
              ),
              Karte(
                titel: gleicherTag(_tag, DateTime.now()) ? 'Heute' : datumMittel(_tag),
                marke: amTag.isEmpty ? null : '${amTag.length}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (amTag.isEmpty) const Leer('Keine Termine an diesem Tag.'),
                    for (final (i, v) in amTag.indexed)
                      Zeile(
                        key: Key('vorkommen-${v.termin.id}-${tagIso(v.beginn)}'),
                        ersteZeile: i == 0,
                        titel: v.termin.titel,
                        unter: [
                          if (v.termin.ganztaegig) 'ganztägig' else if (gleicherTag(v.beginn, _tag)) uhrzeit(v.beginn) else 'seit ${datumMittel(v.beginn)}',
                          if (v.termin.ort != null) v.termin.ort!,
                        ].join(' · '),
                        rechtsWidget: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (v.termin.wiederholung != null) Icon(Icons.repeat, size: 15, color: context.farben.leise),
                            if (v.termin.erinnerungMinuten != null) Icon(Icons.notifications_none, size: 15, color: context.farben.leise),
                          ],
                        ),
                        onTap: () => vorkommenZeigen(context, ref, v),
                      ),
                    Weiter('Termin an diesem Tag', onPressed: () => terminBearbeiten(context, ref, tag: _tag)),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _Monatsraster extends StatelessWidget {
  const _Monatsraster({required this.monat, required this.erster, required this.gewaehlt, required this.mitTermin, required this.onWahl});

  final Monat monat;
  final DateTime erster;
  final DateTime gewaehlt;
  final Set<String> mitTermin;
  final ValueChanged<DateTime> onWahl;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final heute = tagVon(DateTime.now());
    const wochentage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    return Column(
      children: [
        Row(
          children: [
            for (final w in wochentage)
              Expanded(child: Center(child: Text(w, style: TextStyle(fontSize: 11, color: f.leise, fontWeight: FontWeight.w600)))),
          ],
        ),
        const SizedBox(height: 6),
        for (var woche = 0; woche < 6; woche++)
          Row(
            children: [
              for (var t = 0; t < 7; t++)
                Expanded(
                  child: Builder(builder: (context) {
                    final tag = DateTime(erster.year, erster.month, erster.day + woche * 7 + t);
                    final imMonat = monatVon(tag) == monat;
                    final istGewaehlt = gleicherTag(tag, gewaehlt);
                    final istHeute = gleicherTag(tag, heute);
                    return InkWell(
                      key: Key('tag-${tagIso(tag)}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onWahl(tag),
                      child: Container(
                        height: 42,
                        margin: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(
                          color: istGewaehlt ? f.akzent : null,
                          borderRadius: BorderRadius.circular(10),
                          border: istHeute && !istGewaehlt ? Border.all(color: f.akzent) : null,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${tag.day}',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: istHeute || istGewaehlt ? FontWeight.w700 : FontWeight.w400,
                                color: istGewaehlt ? Theme.of(context).colorScheme.onPrimary : (imMonat ? f.text : f.leise.withValues(alpha: .55)),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: mitTermin.contains(tagIso(tag))
                                    ? (istGewaehlt ? Theme.of(context).colorScheme.onPrimary : f.meterFuellung)
                                    : Colors.transparent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
            ],
          ),
      ],
    );
  }
}

class _Suchergebnis extends StatelessWidget {
  const _Suchergebnis({required this.suche, required this.termine, required this.onWahl});
  final String suche;
  final Iterable<Termin> termine;
  final ValueChanged<DateTime> onWahl;

  @override
  Widget build(BuildContext context) {
    final heute = tagVon(DateTime.now());
    final treffer = [
      for (final t in termine)
        if ('${t.titel} ${t.ort ?? ''} ${t.notiz ?? ''}'.toLowerCase().contains(suche))
          (termin: t, naechstes: vorkommenIm(t, heute, DateTime(heute.year + 5, heute.month, heute.day)).firstOrNull),
    ]..sort((a, b) {
        final x = a.naechstes?.beginn ?? a.termin.beginn, y = b.naechstes?.beginn ?? b.termin.beginn;
        return (a.naechstes == null) != (b.naechstes == null) ? (a.naechstes == null ? 1 : -1) : x.compareTo(y);
      });
    return Karte(
      titel: 'Treffer',
      marke: '${treffer.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (treffer.isEmpty) const Leer('Nichts gefunden.'),
          for (final (i, x) in treffer.indexed)
            Zeile(
              ersteZeile: i == 0,
              titel: x.termin.titel,
              unter: x.naechstes != null ? 'Nächster: ${vorkommenZeit(x.naechstes!)}' : 'Vergangen: ${datumKurz(x.termin.beginn)}',
              onTap: () => onWahl(x.naechstes?.beginn ?? x.termin.beginn),
            ),
        ],
      ),
    );
  }
}
