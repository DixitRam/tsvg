// Web: clip bytes play from a data: URL (the <video> element decodes it).
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

VideoPlayerController videoController(Uint8List bytes, String path) {
  final e = path.split('.').last.toLowerCase();
  final mime = switch (e) { 'webm' => 'video/webm', 'mov' => 'video/quicktime', _ => 'video/mp4' };
  return VideoPlayerController.networkUrl(Uri.dataFromBytes(bytes, mimeType: mime));
}
