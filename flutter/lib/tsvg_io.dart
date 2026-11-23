/// dart:io helpers (not for web): open a .tsvg next to its files, or a .tsvgz.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tsvg_core.dart';

/// Opens [path]: a .tsvgz package or a .tsvg document whose relative paths
/// resolve against its directory.
Future<TsvgSource> openTsvgFile(String path) async {
  final bytes = await File(path).readAsBytes();
  if (isZip(bytes)) return packageSource(bytes);
  final dir = File(path).parent.path;
  String full(String p) => '$dir/$p';
  return TsvgCallbackSource(
    utf8.decode(bytes),
    (p) async {
      final f = File(full(p));
      return await f.exists() ? Uint8List.fromList(await f.readAsBytes()) : null;
    },
    exists: (p) => File(full(p)).existsSync(),
  );
}
