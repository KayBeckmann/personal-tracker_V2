import 'package:flutter/material.dart';

import 'thema.dart';

/// Seitenkopf wie im Mock-up: kleine Oberzeile, große Überschrift,
/// gedämpfte Unterzeile, rechts die Hauptaktion.
class Seitenkopf extends StatelessWidget {
  const Seitenkopf({
    super.key,
    required this.oberzeile,
    required this.titel,
    this.unterzeile,
    this.aktionen = const [],
  });

  final String oberzeile;
  final String titel;
  final String? unterzeile;
  final List<Widget> aktionen;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final t = Theme.of(context).textTheme;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          oberzeile.toUpperCase(),
          style: TextStyle(fontSize: 11, letterSpacing: 1.6, fontWeight: FontWeight.w700, color: f.eyebrow),
        ),
        const SizedBox(height: 5),
        Text(titel, style: t.headlineLarge),
        if (unterzeile != null) ...[const SizedBox(height: 6), Text(unterzeile!, style: TextStyle(color: f.gedaempft))],
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 600 || aktionen.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              if (aktionen.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: aktionen),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: text),
            const SizedBox(width: 16),
            Wrap(spacing: 8, runSpacing: 8, children: aktionen),
          ],
        );
      },
    );
  }
}

/// Weiße Karte mit dünnem Rand und großer Rundung.
class Karte extends StatelessWidget {
  const Karte({
    super.key,
    this.titel,
    this.marke,
    this.markeWarnung = false,
    this.aktion,
    required this.child,
    this.innen = const EdgeInsets.all(22),
  });

  final String? titel;
  final String? marke;
  final bool markeWarnung;
  final Widget? aktion;
  final Widget child;
  final EdgeInsets innen;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    // Material statt bemaltem Container: ListTiles und InkWells zeichnen
    // ihre Effekte auf die nächste Material-Fläche.
    return Material(
      color: f.karte,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(19),
        side: BorderSide(color: f.karteRand),
      ),
      child: Padding(
        padding: innen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (titel != null) ...[
              // Wrap: bei wenig Platz rutscht die Aktion unter den Titel.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 2,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(titel!, style: Theme.of(context).textTheme.titleMedium)),
                      if (marke != null) ...[const SizedBox(width: 8), Marke(marke!, warnung: markeWarnung)],
                    ],
                  ),
                  ?aktion,
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// Kleine runde Kennzeichnung („2 wichtig“, „geplant“).
class Marke extends StatelessWidget {
  const Marke(this.text, {super.key, this.warnung = false});
  final String text;
  final bool warnung;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: warnung ? f.warnHg : f.tagHg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: warnung ? f.warnText : f.tagText),
      ),
    );
  }
}

/// Hinweisleiste („Lokal & offline · …“).
class Hinweis extends StatelessWidget {
  const Hinweis({super.key, this.fett, required this.text, this.warnung = false, this.icon, this.aktion});

  final String? fett;
  final String text;
  final bool warnung;
  final IconData? icon;
  final Widget? aktion;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    final farbe = warnung ? f.warnText : f.hinweisText;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
      decoration: BoxDecoration(
        color: warnung ? f.warnHg : f.hinweisHg,
        border: Border.all(color: warnung ? f.warnRand : f.hinweisRand),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(icon ?? (warnung ? Icons.info_outline : Icons.radio_button_checked), size: 16, color: farbe),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (fett != null)
                    TextSpan(
                      text: '$fett · ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  TextSpan(text: text),
                ],
              ),
              style: TextStyle(fontSize: 13, color: farbe),
            ),
          ),
          if (aktion != null) ...[const SizedBox(width: 8), aktion!],
        ],
      ),
    );
  }
}

/// Listenzeile mit Trennlinie, Titel, Unterzeile und rechter Angabe.
class Zeile extends StatelessWidget {
  const Zeile({
    super.key,
    this.vorne,
    required this.titel,
    this.unter,
    this.rechts,
    this.rechtsWidget,
    this.onTap,
    this.ersteZeile = false,
    this.titelStil,
  });

  final Widget? vorne;
  final String titel;
  final String? unter;
  final String? rechts;
  final Widget? rechtsWidget;
  final VoidCallback? onTap;
  final bool ersteZeile;
  final TextStyle? titelStil;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: ersteZeile ? null : Border(top: BorderSide(color: f.linie)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (vorne != null) ...[vorne!, const SizedBox(width: 11)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: titelStil ?? const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (unter != null && unter!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(unter!, style: TextStyle(fontSize: 12, color: f.leise)),
                    ),
                ],
              ),
            ),
            if (rechtsWidget != null) ...[const SizedBox(width: 10), rechtsWidget!],
            if (rechts != null) ...[
              const SizedBox(width: 10),
              Text(rechts!, style: TextStyle(fontSize: 12.5, color: f.akzentText)),
            ],
          ],
        ),
      ),
    );
  }
}

/// „Notizen öffnen →“
class Weiter extends StatelessWidget {
  const Weiter(this.text, {super.key, required this.onPressed});
  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8), minimumSize: Size.zero),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(text)),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_forward, size: 16),
        ],
      ),
    ),
  );
}

/// Leerer Zustand mit kurzer Erklärung.
class Leer extends StatelessWidget {
  const Leer(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(color: context.farben.leise, fontSize: 13)),
  );
}

/// Fortschrittsbalken (gebucht/erwartet gegenüber Rahmen).
class Meter extends StatelessWidget {
  const Meter({super.key, required this.anteil, this.warnung = false});
  final double anteil;
  final bool warnung;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    return Container(
      height: 8,
      decoration: BoxDecoration(color: f.meter, borderRadius: BorderRadius.circular(8)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: anteil.clamp(0, 1).toDouble(),
        child: Container(
          decoration: BoxDecoration(
            color: warnung ? f.meterWarnung : f.meterFuellung,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

/// Zwei Spalten ab mittlerer Breite (wie das Mock-up-Raster), darunter eine.
class Raster extends StatelessWidget {
  const Raster({super.key, required this.kinder, this.verhaeltnis = 1.36});
  final List<Widget> kinder;
  final double verhaeltnis;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (c.maxWidth < 720) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final k in kinder) Padding(padding: const EdgeInsets.only(bottom: 18), child: k)],
        );
      }
      final zeilen = <Widget>[];
      for (var i = 0; i < kinder.length; i += 2) {
        zeilen.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: (verhaeltnis * 100).round(), child: kinder[i]),
                const SizedBox(width: 18),
                Expanded(flex: 100, child: i + 1 < kinder.length ? kinder[i + 1] : const SizedBox()),
              ],
            ),
          ),
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: zeilen);
    },
  );
}

Future<bool> bestaetigen(
  BuildContext context, {
  required String titel,
  required String text,
  String ja = 'Löschen',
  bool gefaehrlich = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titel),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
        FilledButton(
          key: const Key('bestaetigen-ja'),
          style: gefaehrlich ? FilledButton.styleFrom(backgroundColor: ctx.farben.fehler) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ja),
        ),
      ],
    ),
  );
  return ok == true;
}

void meldung(BuildContext context, String text, {bool fehler = false}) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(text), backgroundColor: fehler ? context.farben.fehler : null));
}

/// Dialog mit eigenen Textfeld-Controllern. Sie werden erst freigegeben,
/// wenn die Dialogroute samt Schließ-Animation verschwunden ist.
Future<T?> eingabeDialog<T>(
  BuildContext context, {
  List<String> start = const [''],
  required Widget Function(BuildContext context, List<TextEditingController> felder) builder,
}) => showDialog<T>(
  context: context,
  builder: (_) => _MitControllern(start: start, builder: builder),
);

class _MitControllern extends StatefulWidget {
  const _MitControllern({required this.start, required this.builder});
  final List<String> start;
  final Widget Function(BuildContext context, List<TextEditingController> felder) builder;

  @override
  State<_MitControllern> createState() => _MitControllernState();
}

class _MitControllernState extends State<_MitControllern> {
  late final _felder = [for (final s in widget.start) TextEditingController(text: s)];

  @override
  void dispose() {
    for (final f in _felder) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _felder);
}
