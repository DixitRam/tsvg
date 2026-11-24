// Native: clip bytes → a temp file with the original extension (AVPlayer and
// ExoPlayer sniff the container from it), played with VideoPlayerController.file.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

Directory? _dir;

VideoPlayerController videoController(Uint8List bytes, String path) {
  _dir ??= Directory.systemTemp.createTempSync('tsvg_video');
  final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '.mp4';
  final f = File('${_dir!.path}/${path.hashCode.toUnsigned(32).toRadixString(16)}_${bytes.length}$ext');
  if (!f.existsSync()) f.writeAsBytesSync(bytes, flush: true);
  return VideoPlayerController.file(f);
}
