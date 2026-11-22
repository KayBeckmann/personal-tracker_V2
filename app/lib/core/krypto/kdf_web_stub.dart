import 'dart:typed_data';

Future<Uint8List> pbkdf2Web(Uint8List passwort, Uint8List salz, int iterationen) =>
    throw UnsupportedError('WebCrypto gibt es nur im Browser');
