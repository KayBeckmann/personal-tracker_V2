import 'package:intl/intl.dart';

import '../core/modell/datum.dart';

final _euro = NumberFormat.currency(locale: 'de_DE', symbol: '€', decimalDigits: 2);
final _euroGanz = NumberFormat.currency(locale: 'de_DE', symbol: '€', decimalDigits: 0);

/// `1.234,50 €`; [vorzeichen] zeigt `+` bei Einnahmen.
String euro(int cent, {bool vorzeichen = false, bool ganz = false}) {
  final f = ganz && cent % 100 == 0 ? _euroGanz : _euro;
  final s = f.format(cent / 100);
  return vorzeichen && cent > 0 ? '+$s' : s;
}

/// Liest `12,50`, `-3`, `1.234,5`, `12.50` → Cent; `null` wenn unlesbar.
int? centAusText(String eingabe) {
  var s = eingabe.trim().replaceAll('€', '').replaceAll(' ', '');
  if (s.isEmpty) return null;
  final negativ = s.startsWith('-');
  if (negativ || s.startsWith('+')) s = s.substring(1);
  if (s.contains(',')) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    s = s.replaceAll('.', '');
  }
  if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(s)) return null;
  final teile = s.split('.');
  final cent = int.parse(teile[0]) * 100 + (teile.length > 1 ? int.parse(teile[1].padRight(2, '0')) : 0);
  return negativ ? -cent : cent;
}

String centAlsText(int cent) {
  final a = cent.abs();
  return '${cent < 0 ? '-' : ''}${a ~/ 100},${(a % 100).toString().padLeft(2, '0')}';
}

String wochentag(DateTime d) => DateFormat.EEEE('de_DE').format(d);
String datumLang(DateTime d) => DateFormat('EEEE, d. MMMM', 'de_DE').format(d);
String datumMittel(DateTime d) => DateFormat('EEE, d. MMM', 'de_DE').format(d);
String datumKurz(DateTime d) => DateFormat('dd.MM.yyyy', 'de_DE').format(d);
String uhrzeit(DateTime d) => DateFormat('HH:mm', 'de_DE').format(d);
String monatName(Monat m) => DateFormat('MMMM yyyy', 'de_DE').format(monatsErster(m));
String monatKurz(Monat m) => DateFormat('MMM yy', 'de_DE').format(monatsErster(m));

String vorWieLanger(DateTime t, DateTime jetzt) {
  final d = tagVon(jetzt).difference(tagVon(t.toLocal())).inDays;
  if (d <= 0) return 'heute';
  if (d == 1) return 'gestern';
  return 'vor $d Tagen';
}
