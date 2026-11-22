import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

extension type _Pbkdf2Params._(JSObject _) implements JSObject {
  external factory _Pbkdf2Params({String name, String hash, JSUint8Array salt, int iterations});
}

/// PBKDF2-SHA256 über die WebCrypto-API des Browsers.
Future<Uint8List> pbkdf2Web(Uint8List passwort, Uint8List salz, int iterationen) async {
  final subtle = web.window.crypto.subtle;
  final basis = await subtle
      .importKey('raw', passwort.toJS, 'PBKDF2'.toJS, false, ['deriveBits'.toJS].toJS)
      .toDart;
  final bits = await subtle
      .deriveBits(
        _Pbkdf2Params(name: 'PBKDF2', hash: 'SHA-256', salt: salz.toJS, iterations: iterationen),
        basis,
        256,
      )
      .toDart;
  return bits.toDart.asUint8List();
}
