import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

DatabaseFactory datenbankFabrik() => databaseFactoryIo;

Future<String> datenbankPfad(String name) async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}/$name';
}
