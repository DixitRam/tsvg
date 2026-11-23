// Native: audio bytes → a temp file with the original extension (AVPlayer and
// friends sniff the type from it), then a DeviceFileSource.
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

Directory? _dir;

Future<Source> clipSource(Uint8List bytes, String path, String mime) async {
  _dir ??= await Directory.systemTemp.createTemp('tsvg_audio');
  final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '';
  final name = '${path.hashCode.toUnsigned(32).toRadixString(16)}_${bytes.length}$ext';
  final f = File('${_dir!.path}/$name');
  if (!f.existsSync()) await f.writeAsBytes(bytes, flush: true);
  return DeviceFileSource(f.path, mimeType: mime);
}
