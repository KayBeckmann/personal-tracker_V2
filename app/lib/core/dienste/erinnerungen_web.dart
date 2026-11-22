import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool get _vorhanden => (web.window as JSObject).has('Notification');

String browserErlaubnis() => _vorhanden ? web.Notification.permission : 'unsupported';

Future<void> browserErlaubnisAnfragen() async {
  if (_vorhanden) await web.Notification.requestPermission().toDart;
}

void browserZeigen(String titel, String text) {
  if (_vorhanden) web.Notification(titel, web.NotificationOptions(body: text, tag: 'ptv2-termin'));
}
