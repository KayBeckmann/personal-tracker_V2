// Kalendertage und Monate ohne Uhrzeit/Zeitzone.

DateTime tagVon(DateTime d) => DateTime(d.year, d.month, d.day);

String tagIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime tagAusIso(String s) {
  final t = s.split('-');
  return DateTime(int.parse(t[0]), int.parse(t[1]), int.parse(t[2]));
}

/// Lokale Uhrzeit ohne Zeitzonenangabe (Termine bleiben „14:00“, auch
/// nach Sommerzeitwechsel).
String zeitIso(DateTime d) =>
    '${tagIso(d)}T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

DateTime zeitAusIso(String s) {
  final d = DateTime.parse(s);
  return DateTime(d.year, d.month, d.day, d.hour, d.minute);
}

/// Monat als fortlaufende Zahl (Jahr * 12 + Monat - 1): einfach zu
/// vergleichen und zu zählen.
typedef Monat = int;

Monat monatVon(DateTime d) => d.year * 12 + d.month - 1;
int monatJahr(Monat m) => m ~/ 12;
int monatNummer(Monat m) => m % 12 + 1;
DateTime monatsErster(Monat m) => DateTime(monatJahr(m), monatNummer(m));
int tageImMonat(Monat m) => DateTime(monatJahr(m), monatNummer(m) + 1, 0).day;
String monatIso(Monat m) => '${monatJahr(m)}-${monatNummer(m).toString().padLeft(2, '0')}';

Monat monatAusIso(String s) {
  final t = s.split('-');
  return int.parse(t[0]) * 12 + int.parse(t[1]) - 1;
}

bool gleicherTag(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
