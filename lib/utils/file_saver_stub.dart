import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<String> saveBytesToFile(Uint8List bytes, String fileName) async {
  final Directory documentsDir = await getApplicationDocumentsDirectory();
  final String path = '${documentsDir.path}/$fileName';
  final File file = File(path);
  await file.writeAsBytes(bytes);
  return path;
}
