import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<bool> anfragen() async {
  try {
    final s = web.window.navigator.storage;
    if ((await s.persisted().toDart).toDart) return true;
    return (await s.persist().toDart).toDart;
  } catch (_) {
    return false;
  }
}

Future<bool?> dauerhaft() async {
  try {
    return (await web.window.navigator.storage.persisted().toDart).toDart;
  } catch (_) {
    return null;
  }
}
