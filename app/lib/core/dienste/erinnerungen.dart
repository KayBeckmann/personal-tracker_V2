import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../kalender/vorkommen.dart';
import '../modell/bestand.dart';
import '../modell/datum.dart';
import '../modell/termin.dart';
import 'erinnerungen_web_stub.dart' if (dart.library.js_interop) 'erinnerungen_web.dart';

/// Stand der Erinnerungen für die Einstellungen.
class ErinnerungsStatus {
  const ErinnerungsStatus({required this.erlaubt, this.exakt = true, this.geplant = 0, this.hinweis});

  final bool erlaubt;

  /// Android: exakte Wecker erlaubt — sonst kann eine Erinnerung einige
  /// Minuten später kommen.
  final bool exakt;
  final int geplant;
  final String? hinweis;
}

/// Lokale Terminerinnerungen.
///
/// Android: im System geplant (auch bei geschlossener App) für die nächsten
/// [ErinnerungsDienst.tage] Tage, bei jedem Entsperren/Ändern neu.
/// Web: nur solange der Tab offen ist (Browser-Benachrichtigung).
abstract class ErinnerungsDienst {
  static const tage = 30;
  static const hoechstens = 60;

  Future<ErinnerungsStatus> planen(Bestand bestand, {DateTime? jetzt});
  Future<ErinnerungsStatus> erlaubnisAnfragen();
  Future<void> beenden();
}

/// Text ohne Titel, sofern nicht ausdrücklich gewünscht: der Planungs-
/// speicher des Systems und der Sperrbildschirm sind nicht verschlüsselt.
({String titel, String text}) erinnerungsText(Vorkommen v, {required bool mitTitel, required DateTime jetzt}) {
  final b = v.beginn;
  final heute = tagVon(jetzt);
  final tag = tagVon(b);
  final wann = gleicherTag(tag, heute)
      ? 'Heute'
      : gleicherTag(tag, heute.add(const Duration(days: 1)))
          ? 'Morgen'
          : 'Am ${b.day}.${b.month}.';
  final zeit = v.termin.ganztaegig ? ' (ganztägig)' : ' um ${b.hour}:${b.minute.toString().padLeft(2, '0')}';
  return (titel: mitTitel ? v.termin.titel : 'Termin', text: '$wann$zeit');
}

/// Fällige Erinnerungen im Zeitraum (von, bis], früheste zuerst.
List<({Vorkommen vorkommen, DateTime zeitpunkt})> faelligeErinnerungen(Iterable<Termin> termine, DateTime von, DateTime bis) {
  final mitErinnerung = termine.where((t) => t.erinnerungMinuten != null);
  // Erinnerungen bis zu 7 Tage vorher: Vorkommen etwas weiter fassen.
  final liste = [
    for (final v in alleVorkommen(mitErinnerung, von, bis.add(const Duration(days: 8))))
      if (v.erinnerung case final z? when z.isAfter(von) && !z.isAfter(bis)) (vorkommen: v, zeitpunkt: z),
  ]..sort((a, b) => a.zeitpunkt.compareTo(b.zeitpunkt));
  return liste;
}

ErinnerungsDienst plattformErinnerungen() {
  if (kIsWeb) return WebErinnerungen();
  if (defaultTargetPlatform == TargetPlatform.android) return AndroidErinnerungen();
  return KeineErinnerungen();
}

class KeineErinnerungen implements ErinnerungsDienst {
  @override
  Future<ErinnerungsStatus> planen(Bestand bestand, {DateTime? jetzt}) async =>
      const ErinnerungsStatus(erlaubt: false, hinweis: 'Auf diesem Gerät gibt es keine Erinnerungen.');
  @override
  Future<ErinnerungsStatus> erlaubnisAnfragen() => planen(const Bestand());
  @override
  Future<void> beenden() async {}
}

class AndroidErinnerungen implements ErinnerungsDienst {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _bereit = false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> _start() async {
    if (_bereit) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Europe/Berlin'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    _bereit = true;
  }

  @override
  Future<ErinnerungsStatus> planen(Bestand bestand, {DateTime? jetzt}) async {
    await _start();
    final now = jetzt ?? DateTime.now();
    await _plugin.cancelAll();
    final erlaubt = await _android?.areNotificationsEnabled() ?? false;
    final exakt = await _android?.canScheduleExactNotifications() ?? false;
    final faellig = faelligeErinnerungen(
      bestand.termine.values,
      now,
      now.add(const Duration(days: ErinnerungsDienst.tage)),
    ).take(ErinnerungsDienst.hoechstens).toList();
    var id = 0;
    for (final f in faellig) {
      final t = erinnerungsText(f.vorkommen, mitTitel: bestand.einstellungen.erinnerungMitTitel, jetzt: f.zeitpunkt);
      await _plugin.zonedSchedule(
        id: id++,
        scheduledDate: tz.TZDateTime.from(f.zeitpunkt, tz.local),
        title: t.titel,
        body: t.text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'termine',
            'Terminerinnerungen',
            channelDescription: 'Erinnerungen an Termine aus dem Personal Tracker',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            visibility: NotificationVisibility.private,
          ),
        ),
        androidScheduleMode: exakt ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
    return ErinnerungsStatus(
      erlaubt: erlaubt,
      exakt: exakt,
      geplant: faellig.length,
      hinweis: !erlaubt
          ? 'Benachrichtigungen sind für die App ausgeschaltet.'
          : !exakt
              ? 'Ohne „Wecker und Erinnerungen“ kann eine Erinnerung einige Minuten später kommen.'
              : null,
    );
  }

  @override
  Future<ErinnerungsStatus> erlaubnisAnfragen() async {
    await _start();
    await _android?.requestNotificationsPermission();
    if (!(await _android?.canScheduleExactNotifications() ?? true)) {
      await _android?.requestExactAlarmsPermission();
    }
    return ErinnerungsStatus(
      erlaubt: await _android?.areNotificationsEnabled() ?? false,
      exakt: await _android?.canScheduleExactNotifications() ?? false,
    );
  }

  /// Beim Sperren bleiben geplante Erinnerungen bestehen (sie enthalten
  /// ohne ausdrückliche Einstellung keine Titel).
  @override
  Future<void> beenden() async {}
}

/// Web: prüft jede halbe Minute, solange die App offen und entsperrt ist.
class WebErinnerungen implements ErinnerungsDienst {
  Timer? _timer;
  Bestand _bestand = const Bestand();
  DateTime? _zuletzt;

  /// Für Hinweise in der App, wenn der Browser keine Benachrichtigung darf.
  final _hinweise = StreamController<String>.broadcast();
  Stream<String> get hinweise => _hinweise.stream;

  @override
  Future<ErinnerungsStatus> planen(Bestand bestand, {DateTime? jetzt}) async {
    _bestand = bestand;
    _zuletzt ??= jetzt ?? DateTime.now();
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _pruefen());
    final erlaubt = browserErlaubnis() == 'granted';
    return ErinnerungsStatus(
      erlaubt: erlaubt,
      hinweis: erlaubt
          ? 'Im Browser kommen Erinnerungen nur, solange die App geöffnet ist.'
          : 'Der Browser darf keine Benachrichtigungen zeigen — Erinnerungen erscheinen nur in der geöffneten App.',
    );
  }

  void _pruefen() {
    final jetzt = DateTime.now();
    final von = _zuletzt ?? jetzt;
    _zuletzt = jetzt;
    for (final f in faelligeErinnerungen(_bestand.termine.values, von, jetzt)) {
      final t = erinnerungsText(f.vorkommen, mitTitel: true, jetzt: jetzt);
      if (browserErlaubnis() == 'granted') {
        browserZeigen(_bestand.einstellungen.erinnerungMitTitel ? t.titel : 'Termin', t.text);
      }
      _hinweise.add('${t.titel} · ${t.text}');
    }
  }

  @override
  Future<ErinnerungsStatus> erlaubnisAnfragen() async {
    await browserErlaubnisAnfragen();
    return planen(_bestand);
  }

  @override
  Future<void> beenden() async {
    _timer?.cancel();
    _timer = null;
    _zuletzt = null;
    _bestand = const Bestand();
  }
}
