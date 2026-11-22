import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/finanzen/prognose.dart';
import '../../core/kalender/vorkommen.dart';
import '../../core/modell/datum.dart';
import '../../core/sitzung.dart';
import '../bausteine.dart';
import '../erfassen.dart';
import '../finanzen/prognose_anzeige.dart';
import '../format.dart';
import '../navigation.dart';
import '../notizen/notiz_editor.dart';
import '../termine/termin_formular.dart';
import '../thema.dart';

/// Ruhige Startansicht mit vier klar getrennten Blöcken.
class UebersichtSeite extends ConsumerWidget {
  const UebersichtSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(bestandProvider);
    final sitzung = ref.watch(sitzungProvider);
    final f = context.farben;
    final jetzt = DateTime.now();
    final heute = tagVon(jetzt);
    final heuteListe = alleVorkommen(b.termine.values, heute, heute);
    final morgen = heute.add(const Duration(days: 1));
    final woche = alleVorkommen(b.termine.values, morgen, DateTime(heute.year, heute.month, heute.day + 7))
        .where((v) => !tagVon(v.beginn).isBefore(morgen))
        .toList();
    final p = berechnePrognose(b, jetzt);
    final gehe = ref.read(bereichProvider.notifier).gehe;
    final letzte = b.einstellungen.letzteSicherung;
    final sicherungAlt = letzte == null ? b.anzahlDatensaetze > 0 : jetzt.difference(letzte).inDays > 30;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Seitenkopf(
          oberzeile: datumLang(jetzt),
          titel: 'Ein guter Überblick.',
          unterzeile: 'Heute ist nicht alles gleich wichtig.',
          aktionen: [
            FilledButton.icon(key: const Key('erfassen'), onPressed: () => erfassen(context, ref), icon: const Icon(Icons.add, size: 18), label: const Text('Erfassen')),
          ],
        ),
        const SizedBox(height: 24),
        if (sitzung is Entsperrt && sitzung.defekt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Hinweis(
              warnung: true,
              fett: 'Achtung',
              text: '${sitzung.defekt.length} Datensätze ließen sich nicht entschlüsseln und werden nicht angezeigt. '
                  'Bitte eine Sicherung prüfen.',
            ),
          ),
        if (sicherungAlt)
          Hinweis(
            key: const Key('hinweis-sicherung'),
            warnung: true,
            fett: letzte == null ? 'Noch keine Sicherung' : 'Letzte Sicherung ${vorWieLanger(letzte, jetzt)}',
            text: 'Die Daten liegen nur auf diesem Gerät. Eine verschlüsselte Sicherung schützt vor Verlust.',
            aktion: TextButton(onPressed: () => gehe(Bereich.einstellungen), child: const Text('Sichern')),
          )
        else
          Hinweis(
            fett: 'Lokal & verschlüsselt',
            text: letzte == null
                ? 'Kein Konto und kein Server nötig.'
                : 'Kein Konto und kein Server nötig · letzte Sicherung ${vorWieLanger(letzte, jetzt)}.',
          ),
        const SizedBox(height: 22),
        Raster(
          kinder: [
            Karte(
              key: const Key('karte-heute'),
              titel: 'Heute',
              marke: heuteListe.isEmpty ? null : '${heuteListe.length} ${heuteListe.length == 1 ? 'Termin' : 'Termine'}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (heuteListe.isEmpty) const Leer('Heute stehen keine Termine an.'),
                  for (final (i, v) in heuteListe.take(5).indexed)
                    Zeile(
                      ersteZeile: i == 0,
                      vorne: Icon(Icons.circle_outlined, size: 18, color: f.meterFuellung),
                      titel: v.termin.titel,
                      unter: [
                        v.termin.ganztaegig ? 'ganztägig' : uhrzeit(v.beginn),
                        if (v.termin.ort != null) v.termin.ort!,
                      ].join(' · '),
                      onTap: () => vorkommenZeigen(context, ref, v),
                    ),
                  if (heuteListe.length > 5) Leer('… und ${heuteListe.length - 5} weitere'),
                  Weiter('Termine öffnen', onPressed: () => gehe(Bereich.termine)),
                ],
              ),
            ),
            Karte(
              key: const Key('karte-woche'),
              titel: 'Diese Woche',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (woche.isEmpty) const Leer('Die nächsten sieben Tage sind frei.'),
                  for (final (i, v) in woche.take(4).indexed)
                    Zeile(
                      ersteZeile: i == 0,
                      titel: v.termin.titel,
                      unter: '${wochentag(v.beginn)}${v.termin.ganztaegig ? '' : ' · ${uhrzeit(v.beginn)}'}',
                      onTap: () => vorkommenZeigen(context, ref, v),
                    ),
                  if (woche.length > 4) Leer('… und ${woche.length - 4} weitere'),
                ],
              ),
            ),
            Karte(
              key: const Key('karte-geld'),
              titel: 'Geld im Blick',
              marke: monatKurz(p.monat),
              child: b.konten.isEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Leer('Noch kein Konto angelegt.'),
                        Weiter('Haushaltsbuch öffnen', onPressed: () => gehe(Bereich.finanzen)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GeldImBlick(p: p),
                        Weiter('Zusammensetzung ansehen', onPressed: () => zusammensetzungZeigen(context, p)),
                      ],
                    ),
            ),
            Karte(
              key: const Key('karte-notizen'),
              titel: 'Notizen',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (b.notizen.isEmpty) const Leer('Noch keine Notizen.'),
                  for (final n in b.notizenNeuesteZuerst.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Material(
                        color: f.notizHg,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => notizOeffnen(context, n),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(text: '„${n.anzeigeTitel}“'),
                                TextSpan(text: ' · ${datumKurz(n.geaendert.toLocal())} · Markdown', style: TextStyle(fontSize: 12, color: f.leise)),
                              ]),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Weiter('Notizen öffnen', onPressed: () => gehe(Bereich.notizen)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
