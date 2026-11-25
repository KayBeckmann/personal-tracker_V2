import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/krypto/recovery_schluessel.dart';
import '../bausteine.dart';
import '../thema.dart';

/// Ruhiger Rahmen für Einrichtung und Entsperren.
class ZugangsRahmen extends StatelessWidget {
  const ZugangsRahmen({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    return Scaffold(
      backgroundColor: f.hintergrund,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                decoration: BoxDecoration(
                  color: f.flaeche,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [BoxShadow(color: f.schatten, blurRadius: 70, offset: const Offset(0, 24))],
                ),
                padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [const Markenzeichen(), const SizedBox(height: 26), child],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Markenzeichen extends StatelessWidget {
  const Markenzeichen({super.key, this.unter = 'V2 · LOKAL'});
  final String unter;

  @override
  Widget build(BuildContext context) {
    final f = context.farben;
    return Row(
      children: [
        const Bildmarke(),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'personal'),
                  TextSpan(text: 'tracker', style: TextStyle(color: f.marke)),
                ]),
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.8, color: f.text),
              ),
              Text(unter, style: TextStyle(fontSize: 11, color: f.leise, letterSpacing: .3)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Logo wie das App-Icon (Quelle: assets/logo/logo.svg): Fortschrittsring
/// zu drei Vierteln mit Haken, auf Akzentgrün.
class Bildmarke extends StatelessWidget {
  const Bildmarke({super.key, this.groesse = 34});
  final double groesse;

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: CustomPaint(size: Size.square(groesse), painter: const _BildmarkeMaler()));
}

class _BildmarkeMaler extends CustomPainter {
  const _BildmarkeMaler();

  @override
  void paint(Canvas canvas, Size size) {
    // Koordinaten wie im SVG (1024er Raster).
    canvas.scale(size.width / 1024);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 1024, 1024), const Radius.circular(232)),
      Paint()..color = const Color(0xFF286A53),
    );
    final strich = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 64
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final ring = Rect.fromCircle(center: const Offset(512, 512), radius: 270);
    canvas.drawCircle(const Offset(512, 512), 270, strich..color = const Color(0xFF3F8A6C));
    canvas.drawArc(ring, -math.pi / 2, math.pi * 1.5, false, strich..color = const Color(0xFFFBFCF8));
    canvas.drawPath(
      Path()
        ..moveTo(392, 522)
        ..lineTo(478, 606)
        ..lineTo(640, 428),
      strich..strokeWidth = 68,
    );
  }

  @override
  bool shouldRepaint(_BildmarkeMaler oldDelegate) => false;
}

class PasswortFeld extends StatefulWidget {
  const PasswortFeld({
    super.key,
    required this.controller,
    this.label = 'Passwort',
    this.validator,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<PasswortFeld> createState() => _PasswortFeldState();
}

class _PasswortFeldState extends State<PasswortFeld> {
  bool _sichtbar = false;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: widget.controller,
        obscureText: !_sichtbar,
        autofocus: widget.autofocus,
        autocorrect: false,
        enableSuggestions: false,
        validator: widget.validator,
        onFieldSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          labelText: widget.label,
          suffixIcon: IconButton(
            tooltip: _sichtbar ? 'Verbergen' : 'Anzeigen',
            icon: Icon(_sichtbar ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _sichtbar = !_sichtbar),
          ),
        ),
      );
}

String? passwortRegel(String? v) =>
    (v ?? '').length < 8 ? 'Mindestens 8 Zeichen — lieber ein Satz als ein kurzes Wort.' : null;

class Laedt extends StatelessWidget {
  const Laedt(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class Fehlertext extends StatelessWidget {
  const Fehlertext(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text, key: const Key('zugang-fehler'), style: TextStyle(color: context.farben.fehler)),
      );
}

/// Recovery-Schlüssel groß und auswählbar, mit „Kopieren“.
class RecoveryAnzeige extends StatelessWidget {
  const RecoveryAnzeige(this.schluessel, {super.key});
  final RecoverySchluessel schluessel;

  @override
  Widget build(BuildContext context) {
    final text = schluessel.anzeigen();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: context.farben.notizHg, borderRadius: BorderRadius.circular(12)),
          // Eigene Semantik: SelectableText ist für Screenreader sonst stumm.
          child: Semantics(
            label: 'Recovery-Schlüssel $text',
            container: true,
            child: ExcludeSemantics(
              child: SelectableText(
                text,
                key: const Key('recovery-anzeige'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 1.5, height: 1.6),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Kopieren'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              meldung(context, 'Kopiert — nach dem Aufschreiben die Zwischenablage leeren.');
            },
          ),
        ),
      ],
    );
  }
}
