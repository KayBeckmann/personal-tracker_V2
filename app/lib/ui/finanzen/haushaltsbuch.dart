import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/finanzen/prognose.dart';
import '../../core/modell/bestand.dart';
import '../../core/modell/datum.dart';
import '../../core/modell/finanzen.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';
import 'formulare.dart';
import 'prognose_anzeige.dart';

class HaushaltsbuchSeite extends ConsumerStatefulWidget {
  const HaushaltsbuchSeite({super.key});

  @override
  ConsumerState<HaushaltsbuchSeite> createState() => _HaushaltsbuchSeiteState();
}

class _HaushaltsbuchSeiteState extends ConsumerState<HaushaltsbuchSeite> {
  Monat _monat = monatVon(DateTime.now());
  String? _kontoFilter;

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(bestandProvider);
    final heute = DateTime.now();
    final p = berechnePrognose(b, heute, monat: _monat);
    final aktivKonten = b.kontenSortiert.where((k) => !k.archiviert).toList();
    final f = context.farben;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: 'Haushaltsbuch · EUR',
          titel: 'Geld im Blick.',
          unterzeile: 'Gebucht, geplant und geschätzt — sauber getrennt.',
          aktionen: [
            FilledButton.icon(
              key: const Key('buchung-neu'),
              onPressed: aktivKonten.isEmpty ? () => kontoBearbeiten(context, ref) : () => buchungBearbeiten(context, ref, datum: _vorschlagsDatum()),
              icon: const Icon(Icons.add, size: 18),
              label: Text(aktivKonten.isEmpty ? 'Erstes Konto' : 'Buchung'),
            ),
            if (aktivKonten.length >= 2)
              OutlinedButton.icon(
                key: const Key('umbuchung-neu'),
                onPressed: () => umbuchungBearbeiten(context, ref),
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Umbuchung'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            IconButton(key: const Key('hb-monat-zurueck'), onPressed: () => setState(() => _monat--), icon: const Icon(Icons.chevron_left)),
            Text(monatName(_monat), key: const Key('hb-monat'), style: Theme.of(context).textTheme.titleMedium),
            IconButton(key: const Key('hb-monat-vor'), onPressed: () => setState(() => _monat++), icon: const Icon(Icons.chevron_right)),
            if (_monat != monatVon(heute))
              TextButton(onPressed: () => setState(() => _monat = monatVon(heute)), child: const Text('Aktueller Monat')),
          ],
        ),
        const SizedBox(height: 10),
        if (b.konten.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Hinweis(
              fett: 'Los geht’s',
              text: 'Lege zuerst ein Konto an — z. B. Girokonto, Portemonnaie oder Depot. Buchungen gehören immer zu genau einem Konto.',
            ),
          ),
        Raster(
          kinder: [
            Karte(
              titel: _monat == monatVon(heute) ? 'Dieser Monat' : monatName(_monat),
              marke: p.abgeschlossen ? 'abgeschlossen' : null,
              aktion: TextButton(key: const Key('rahmen-setzen'), onPressed: () => rahmenSetzen(context, ref), child: Text(b.einstellungen.ausgabenrahmenCent == null ? 'Rahmen setzen' : 'Rahmen ändern')),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GeldImBlick(p: p),
                  if (p.gebuchtEinnahmenCent != 0 || p.offenEinnahmenCent != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Einnahmen: ${euro(p.gebuchtEinnahmenCent, ganz: true)} gebucht'
                        '${p.abgeschlossen ? '' : ' · ${euro(p.offenEinnahmenCent, ganz: true)} geplant'}',
                        style: TextStyle(fontSize: 12, color: f.einnahme),
                      ),
                    ),
                  if (!p.abgeschlossen && p.offen.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text('Noch offen', style: TextStyle(fontWeight: FontWeight.w600, color: f.gedaempft, fontSize: 13)),
                    for (final (i, o) in p.offen.indexed) _OffenZeile(posten: o, monat: _monat, erste: i == 0),
                  ],
                  Weiter('Zusammensetzung ansehen', onPressed: () => zusammensetzungZeigen(context, p)),
                ],
              ),
            ),
            Karte(
              titel: 'Konten',
              aktion: TextButton.icon(key: const Key('konto-neu'), onPressed: () => kontoBearbeiten(context, ref), icon: const Icon(Icons.add, size: 18), label: const Text('Konto')),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (b.konten.isEmpty) const Leer('Noch kein Konto.'),
                  for (final (i, k) in b.kontenSortiert.indexed)
                    Zeile(
                      key: Key('konto-${k.id}'),
                      ersteZeile: i == 0,
                      titel: k.name,
                      titelStil: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: k.archiviert ? f.leise : null),
                      unter: '${k.art.bezeichnung}${k.archiviert ? ' · archiviert' : ''}',
                      rechtsWidget: Text(
                        euro(b.saldoCent(k.id)),
                        key: Key('saldo-${k.id}'),
                        style: TextStyle(fontWeight: FontWeight.w600, color: b.saldoCent(k.id) < 0 ? f.fehler : f.text),
                      ),
                      onTap: () => kontoBearbeiten(context, ref, konto: k),
                    ),
                  if (b.konten.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Kontostand = Anfangsstand + gebuchte Buchungen. Geplantes zählt nicht.', style: TextStyle(fontSize: 12, color: f.leise)),
                    ),
                ],
              ),
            ),
            _BuchungenKarte(bestand: b, monat: _monat, kontoFilter: _kontoFilter, onFilter: (k) => setState(() => _kontoFilter = k)),
            _PlaeneKarte(bestand: b, monat: _monat),
          ],
        ),
      ],
    );
  }

  DateTime _vorschlagsDatum() {
    final heute = DateTime.now();
    return _monat == monatVon(heute) ? heute : monatsErster(_monat);
  }
}

class _OffenZeile extends ConsumerWidget {
  const _OffenZeile({required this.posten, required this.monat, required this.erste});
  final OffenerPosten posten;
  final Monat monat;
  final bool erste;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(bestandProvider);
    final f = context.farben;
    return Zeile(
      ersteZeile: erste,
      titel: posten.empfaenger.isEmpty ? '(ohne Bezeichnung)' : posten.empfaenger,
      unter: '${datumMittel(posten.datum)} · ${posten.planId != null ? 'monatlich' : 'einmalig geplant'}',
      rechtsWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(euro(posten.betragCent, vorzeichen: true), style: TextStyle(fontSize: 13, color: posten.betragCent > 0 ? f.einnahme : f.text)),
          const SizedBox(width: 6),
          TextButton(
            key: Key('offen-buchen-${posten.planId ?? posten.buchungId}'),
            style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
            onPressed: () {
              if (posten.planId != null) {
                planBuchenDialog(context, ref, b.plaene[posten.planId]!, monat);
              } else {
                ref.read(sitzungProvider.notifier).geplantBuchen(b.buchungen[posten.buchungId]!);
              }
            },
            child: const Text('Buchen'),
          ),
        ],
      ),
    );
  }
}

class _BuchungenKarte extends ConsumerWidget {
  const _BuchungenKarte({required this.bestand, required this.monat, required this.kontoFilter, required this.onFilter});
  final Bestand bestand;
  final Monat monat;
  final String? kontoFilter;
  final ValueChanged<String?> onFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    final liste = bestand.buchungen.values
        .where((x) => monatVon(x.datum) == monat && (kontoFilter == null || x.kontoId == kontoFilter))
        // Umbuchungen nur einmal (Abgang) zeigen, außer beim Kontofilter.
        .where((x) => kontoFilter != null || !x.istUmbuchung || x.betragCent < 0)
        .toList()
      ..sort((a, c) {
        final d = c.datum.compareTo(a.datum);
        return d != 0 ? d : c.geaendert.compareTo(a.geaendert);
      });
    return Karte(
      titel: 'Buchungen',
      marke: liste.isEmpty ? null : '${liste.length}',
      aktion: bestand.konten.length < 2
          ? null
          : PopupMenuButton<String?>(
              tooltip: 'Nach Konto filtern',
              initialValue: kontoFilter,
              onSelected: onFilter,
              itemBuilder: (_) => [
                const PopupMenuItem(value: null, child: Text('Alle Konten')),
                for (final k in bestand.kontenSortiert) PopupMenuItem(value: k.id, child: Text(k.name)),
              ],
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(kontoFilter == null ? 'Alle Konten' : bestand.konten[kontoFilter]?.name ?? '', style: TextStyle(color: f.akzentText, fontSize: 13)),
                    Icon(Icons.arrow_drop_down, color: f.akzentText),
                  ],
                ),
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (liste.isEmpty) Leer('Keine Buchungen in ${monatName(monat)}.'),
          for (final (i, x) in liste.indexed) _BuchungZeile(buchung: x, bestand: bestand, erste: i == 0),
        ],
      ),
    );
  }
}

class _BuchungZeile extends ConsumerWidget {
  const _BuchungZeile({required this.buchung, required this.bestand, required this.erste});
  final Buchung buchung;
  final Bestand bestand;
  final bool erste;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = context.farben;
    final x = buchung;
    final konto = bestand.konten[x.kontoId]?.name ?? '?';
    final gegen = bestand.gegenbuchung(x);
    final titel = x.istUmbuchung
        ? (x.betragCent < 0 ? '$konto › ${bestand.konten[gegen?.kontoId]?.name ?? '?'}' : '${bestand.konten[gegen?.kontoId]?.name ?? '?'} › $konto')
        : (x.empfaenger.isEmpty ? '(ohne Empfänger)' : x.empfaenger);
    return Zeile(
      key: Key('buchung-${x.id}'),
      ersteZeile: erste,
      titel: titel,
      unter: [
        datumMittel(x.datum),
        if (x.istUmbuchung) 'Umbuchung' else konto,
        if (x.planId != null) 'wiederkehrend',
        if (x.bemerkung != null) x.bemerkung!,
      ].join(' · '),
      rechtsWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!x.gebucht) ...[const Marke('geplant', warnung: true), const SizedBox(width: 8)],
          Text(
            x.istUmbuchung ? euro(x.betragCent.abs()) : euro(x.betragCent, vorzeichen: true),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: x.istUmbuchung ? f.gedaempft : (x.betragCent > 0 ? f.einnahme : f.text),
            ),
          ),
        ],
      ),
      onTap: () => x.istUmbuchung ? umbuchungBearbeiten(context, ref, umbuchungId: x.umbuchungId) : buchungBearbeiten(context, ref, buchung: x),
    );
  }
}

class _PlaeneKarte extends ConsumerWidget {
  const _PlaeneKarte({required this.bestand, required this.monat});
  final Bestand bestand;
  final Monat monat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plaene = bestand.plaene.values.toList()..sort((a, b) => a.tag.compareTo(b.tag));
    final erledigt = {
      for (final x in bestand.buchungen.values)
        if (x.planId != null && x.planMonat == monat) x.planId!,
    };
    return Karte(
      titel: 'Wiederkehrend',
      aktion: TextButton(
        key: const Key('plan-neu'),
        onPressed: bestand.konten.isEmpty ? null : () => planBearbeiten(context, ref),
        child: const Text('Posten hinzufügen'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plaene.isEmpty) const Leer('Monatlich geplante Posten wie Miete oder Gehalt — sie zählen als „geplant“, bis du sie buchst.'),
          for (final (i, p) in plaene.indexed)
            Zeile(
              key: Key('plan-${p.id}'),
              ersteZeile: i == 0,
              titel: p.empfaenger,
              unter: [
                'am ${p.tag}.',
                bestand.konten[p.kontoId]?.name ?? '?',
                if (!p.giltIm(monat)) 'nicht in ${monatKurz(monat)}' else if (erledigt.contains(p.id)) 'gebucht' else 'offen',
              ].join(' · '),
              rechts: euro(p.betragCent, vorzeichen: true),
              onTap: () => planBearbeiten(context, ref, plan: p),
            ),
        ],
      ),
    );
  }
}
