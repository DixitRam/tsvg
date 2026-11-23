// Web: audio bytes play from memory.
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

Future<Source> clipSource(Uint8List bytes, String path, String mime) async => BytesSource(bytes, mimeType: mime);
