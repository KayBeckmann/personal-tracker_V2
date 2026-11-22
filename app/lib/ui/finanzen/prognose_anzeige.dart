import 'package:flutter/material.dart';

import '../../core/finanzen/prognose.dart';
import '../bausteine.dart';
import '../format.dart';
import '../thema.dart';

/// „Geld im Blick“ wie im Mock-up: gebucht als große Zahl, darunter
/// geplant und geschätzt getrennt; der Balken nur bei gesetztem Rahmen.
class GeldImBlick extends StatelessWidget {
  const GeldImBlick({super.key, required this.p});
  final Prognose p;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final rahmen = p.ausgabenrahmenCent;
    final rest = p.restVariabelCent;
    final teile = [
      if (p.abgeschlossen) 'Monat abgeschlossen' else 'Noch bekannt geplant: ${euro(p.offenAusgabenCent, ganz: true)}',
      if (!p.abgeschlossen)
        rest == null ? 'Variable Kosten: noch keine Schätzung (kein abgeschlossener Monat)' : 'Variable Kosten: grobe Schätzung ${euro(rest, ganz: true)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 8,
          children: [
            Text(
              euro(p.gebuchtAusgabenCent, ganz: true),
              key: const Key('geld-gebucht'),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -1.2),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text('bereits ausgegeben', style: TextStyle(color: f.leise)),
            ),
          ],
        ),
        if (rahmen != null && rahmen > 0) ...[
          const SizedBox(height: 14),
          Meter(anteil: p.erwartetGesamtAusgabenCent / rahmen, warnung: (p.rahmenRestCent ?? 0) < 0),
          const SizedBox(height: 8),
          Text(
            (p.rahmenRestCent ?? 0) >= 0
                ? 'Rahmen ${euro(rahmen, ganz: true)} · voraussichtlich ${euro(p.rahmenRestCent!, ganz: true)} übrig'
                : 'Rahmen ${euro(rahmen, ganz: true)} · voraussichtlich ${euro(-p.rahmenRestCent!, ganz: true)} darüber',
            style: TextStyle(fontSize: 12, color: (p.rahmenRestCent ?? 0) < 0 ? f.warnText : f.gedaempft),
          ),
        ] else
          const SizedBox(height: 10),
        const SizedBox(height: 6),
        Text(teile.join(' · '), style: TextStyle(fontSize: 12, color: f.gedaempft)),
      ],
    );
  }
}

/// Nachvollziehbare Zusammensetzung der Vorschau.
Future<void> zusammensetzungZeigen(BuildContext context, Prognose p) => showDialog<void>(
      context: context,
      builder: (ctx) {
        final f = ctx.farben;
        Widget zeile(String a, String b, {bool fett = false, String? unter}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a, style: TextStyle(fontWeight: fett ? FontWeight.w700 : FontWeight.w400)),
                        if (unter != null) Text(unter, style: TextStyle(fontSize: 12, color: f.leise)),
                      ],
                    ),
                  ),
                  Text(b, style: TextStyle(fontWeight: fett ? FontWeight.w700 : FontWeight.w400)),
                ],
              ),
            );
        final rest = p.restVariabelCent;
        return AlertDialog(
          title: Text('So setzt sich ${monatName(p.monat)} zusammen'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              key: const Key('zusammensetzung'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  zeile('Gebuchte Ausgaben', euro(p.gebuchtAusgabenCent), unter: 'davon variabel ${euro(p.gebuchtVariabelCent)}'),
                  if (!p.abgeschlossen) ...[
                    zeile('Bekannt geplant, noch offen', euro(p.offenAusgabenCent), unter: '${p.offen.where((o) => o.betragCent < 0).length} Posten'),
                    zeile(
                      'Variable Kosten, geschätzt',
                      rest == null ? '—' : euro(rest),
                      unter: p.durchschnittVariabelCent == null
                          ? 'Kein abgeschlossener Monat — daher keine Schätzung'
                          : 'Ø ${euro(p.durchschnittVariabelCent!)} aus ${p.basis.map((b) => '${monatKurz(b.monat)}: ${euro(b.cent, ganz: true)}').join(', ')} '
                              '− schon gebucht ${euro(p.gebuchtVariabelCent)}',
                    ),
                  ],
                  const Divider(height: 20),
                  zeile('Ausgaben bis Monatsende (erwartet)', euro(p.erwartetGesamtAusgabenCent), fett: true),
                  if (p.ausgabenrahmenCent != null)
                    zeile(
                      'Dein Rahmen',
                      euro(p.ausgabenrahmenCent!),
                      unter: (p.rahmenRestCent ?? 0) >= 0
                          ? 'voraussichtlich ${euro(p.rahmenRestCent!)} übrig'
                          : 'voraussichtlich ${euro(-p.rahmenRestCent!)} darüber',
                    ),
                  const Divider(height: 20),
                  zeile('Einnahmen gebucht', euro(p.gebuchtEinnahmenCent)),
                  if (!p.abgeschlossen) zeile('Einnahmen geplant, noch offen', euro(p.offenEinnahmenCent)),
                  const SizedBox(height: 12),
                  Text(
                    'Gebucht, geplant und geschätzt sind getrennte Werte — keiner davon ist ein Kontostand. '
                    'Umbuchungen zählen nie. Geplante und wiederkehrende Posten fließen nicht in den Durchschnitt.',
                    style: TextStyle(fontSize: 12, color: f.leise),
                  ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen'))],
        );
      },
    );
