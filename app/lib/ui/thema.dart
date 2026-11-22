import 'package:flutter/material.dart';

/// Farben nach Mock-up „Ruhiger Tagesblick“, dazu eine dunkle Variante.
@immutable
class TrackerFarben extends ThemeExtension<TrackerFarben> {
  const TrackerFarben({
    required this.hintergrund,
    required this.flaeche,
    required this.seite,
    required this.seiteRand,
    required this.karte,
    required this.karteRand,
    required this.text,
    required this.gedaempft,
    required this.leise,
    required this.eyebrow,
    required this.akzent,
    required this.akzentText,
    required this.marke,
    required this.navAktiv,
    required this.navAktivText,
    required this.tagHg,
    required this.tagText,
    required this.hinweisHg,
    required this.hinweisRand,
    required this.hinweisText,
    required this.warnHg,
    required this.warnRand,
    required this.warnText,
    required this.fehler,
    required this.linie,
    required this.meter,
    required this.meterFuellung,
    required this.meterWarnung,
    required this.notizHg,
    required this.einnahme,
    required this.schatten,
  });

  final Color hintergrund, flaeche, seite, seiteRand, karte, karteRand, text, gedaempft, leise, eyebrow;
  final Color akzent, akzentText, marke, navAktiv, navAktivText, tagHg, tagText;
  final Color hinweisHg, hinweisRand, hinweisText, warnHg, warnRand, warnText, fehler;
  final Color linie, meter, meterFuellung, meterWarnung, notizHg, einnahme, schatten;

  static const hell = TrackerFarben(
    hintergrund: Color(0xFFE9EDEA),
    flaeche: Color(0xFFFBFCF8),
    seite: Color(0xFFF1F4ED),
    seiteRand: Color(0xFFDCE5DB),
    karte: Color(0xFFFFFFFF),
    karteRand: Color(0xFFE1E8DF),
    text: Color(0xFF21342E),
    gedaempft: Color(0xFF718177),
    leise: Color(0xFF87958A),
    eyebrow: Color(0xFF648471),
    akzent: Color(0xFF286A53),
    akzentText: Color(0xFF2D7858),
    marke: Color(0xFF418678),
    navAktiv: Color(0xFFDCEBE1),
    navAktivText: Color(0xFF204E3C),
    tagHg: Color(0xFFE6F3EA),
    tagText: Color(0xFF367352),
    hinweisHg: Color(0xFFEBF4ED),
    hinweisRand: Color(0xFFCCE4D3),
    hinweisText: Color(0xFF365B44),
    warnHg: Color(0xFFFBF3E4),
    warnRand: Color(0xFFEBD9B4),
    warnText: Color(0xFF7A5A1E),
    fehler: Color(0xFFB3412F),
    linie: Color(0xFFEDF1EC),
    meter: Color(0xFFE5ECE5),
    meterFuellung: Color(0xFF6AAB87),
    meterWarnung: Color(0xFFD08C45),
    notizHg: Color(0xFFF6F8F3),
    einnahme: Color(0xFF2D7858),
    schatten: Color(0x26193E32),
  );

  static const dunkel = TrackerFarben(
    hintergrund: Color(0xFF0E1512),
    flaeche: Color(0xFF141D19),
    seite: Color(0xFF111915),
    seiteRand: Color(0xFF223029),
    karte: Color(0xFF1A2520),
    karteRand: Color(0xFF26352E),
    text: Color(0xFFE2EBE5),
    gedaempft: Color(0xFF9AAEA2),
    leise: Color(0xFF7F9387),
    eyebrow: Color(0xFF8FB39C),
    akzent: Color(0xFF5DB28C),
    akzentText: Color(0xFF7CC7A2),
    marke: Color(0xFF6FB8A5),
    navAktiv: Color(0xFF203A2D),
    navAktivText: Color(0xFFBFE3CC),
    tagHg: Color(0xFF213A2D),
    tagText: Color(0xFF9ED4B4),
    hinweisHg: Color(0xFF172A21),
    hinweisRand: Color(0xFF2A4636),
    hinweisText: Color(0xFFA9D3B8),
    warnHg: Color(0xFF2E2615),
    warnRand: Color(0xFF4D3F20),
    warnText: Color(0xFFE6C37F),
    fehler: Color(0xFFEF8E7C),
    linie: Color(0xFF223029),
    meter: Color(0xFF26352E),
    meterFuellung: Color(0xFF5DB28C),
    meterWarnung: Color(0xFFD69A57),
    notizHg: Color(0xFF16201C),
    einnahme: Color(0xFF7CC7A2),
    schatten: Color(0x66000000),
  );

  @override
  TrackerFarben copyWith() => this;

  @override
  TrackerFarben lerp(TrackerFarben? other, double t) => t < 0.5 || other == null ? this : other;
}

extension TrackerFarbenKontext on BuildContext {
  TrackerFarben get farben => Theme.of(this).extension<TrackerFarben>()!;
}

ThemeData trackerThema(Brightness helligkeit) {
  final f = helligkeit == Brightness.light ? TrackerFarben.hell : TrackerFarben.dunkel;
  final schema = ColorScheme.fromSeed(seedColor: const Color(0xFF286A53), brightness: helligkeit).copyWith(
    primary: f.akzent,
    onPrimary: helligkeit == Brightness.light ? Colors.white : const Color(0xFF0B1F16),
    surface: f.flaeche,
    onSurface: f.text,
    onSurfaceVariant: f.gedaempft,
    outline: f.karteRand,
    outlineVariant: f.linie,
    error: f.fehler,
  );
  final basis = ThemeData(useMaterial3: true, colorScheme: schema, brightness: helligkeit, fontFamily: 'NotoSans');
  final text = basis.textTheme.apply(bodyColor: f.text, displayColor: f.text);
  const pill = StadiumBorder();
  return basis.copyWith(
    scaffoldBackgroundColor: f.flaeche,
    extensions: [f],
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1.6, height: 1.15),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.6),
      titleMedium: text.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -.3),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12.5, color: f.leise),
    ),
    dividerTheme: DividerThemeData(color: f.linie, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: pill,
        backgroundColor: f.akzent,
        foregroundColor: schema.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontFamily: 'NotoSans', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        foregroundColor: f.akzentText,
        side: BorderSide(color: f.hinweisRand),
        backgroundColor: f.karte,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: f.akzentText,
        textStyle: const TextStyle(fontFamily: 'NotoSans', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: f.karte,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: f.karteRand)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: f.karteRand)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: f.akzent, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: f.karte,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: f.karte,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
  );
}
