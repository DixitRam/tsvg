// Fonts and images a document needs, loaded from its source.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/audio.dart' show assetPath;
import '../core/model.dart';
import '../core/source.dart';

/// Decoded images (by asset id and by path, plus `<video>` poster frames) and
/// the fonts registered for a document.
class TsvgMedia extends ChangeNotifier {
  TsvgMedia(this.doc);
  final TsvgDoc doc;
  final Map<String, ui.Image> _images = {};
  final List<String> errors = [];

  /// Bumped whenever an image arrives (painters repaint).
  int version = 0;

  static final Set<String> _loadedFonts = {};

  ui.Image? image(String ref) => _images[ref] ?? _images[assetPath(doc, ref) ?? ''];

  /// Loads every `<font>` (via [FontLoader]) and every image asset.
  static Future<TsvgMedia> load(TsvgDoc doc, TsvgSource source) async {
    final m = TsvgMedia(doc);
    await Future.wait([m._loadFonts(source), m._loadImages(source)]);
    return m;
  }

  Future<void> _loadFonts(TsvgSource source) async {
    final byFamily = <String, List<TsvgFont>>{};
    for (final f in doc.fonts) {
      if (f.src == null) continue;
      if (_loadedFonts.contains('${f.family}|${f.src}')) continue;
      byFamily.putIfAbsent(f.family, () => []).add(f);
    }
    for (final e in byFamily.entries) {
      final loader = FontLoader(e.key);
      var any = false;
      for (final f in e.value) {
        final bytes = await source.read(f.src!);
        if (bytes == null) {
          errors.add('font ${f.family}: ${f.src} not found');
          continue;
        }
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        _loadedFonts.add('${f.family}|${f.src}');
        any = true;
      }
      if (any) {
        try {
          await loader.load();
        } catch (err) {
          errors.add('font ${e.key}: $err');
        }
      }
    }
  }

  Future<void> _loadImages(TsvgSource source) async {
    final futures = <Future<void>>[];
    // images by id and path; <video> clips: their poster frame by path
    final want = <(String, String)>[
      for (final e in doc.assets.entries)
        if (e.value.type == 'image' && e.value.src != null)
          (e.key, e.value.src!)
        else if (e.value.type == 'video' && (e.value.poster ?? '').isNotEmpty)
          (e.value.poster!, e.value.poster!),
    ];
    for (final (id, src) in want) {
      futures.add(() async {
        try {
          final img = _images[src] ?? await decode(await source.read(src));
          if (img == null) {
            errors.add('image $id: $src not found');
            return;
          }
          _images[src] = img;
          _images[id] = img;
          doc.aspects[src] = doc.aspects[id] = img.width / img.height;
          version++;
          notifyListeners();
        } catch (err) {
          errors.add('image $id: $err');
        }
      }());
    }
    await Future.wait(futures);
  }

  static Future<ui.Image?> decode(Uint8List? bytes) async {
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  @override
  void dispose() {
    for (final i in _images.values.toSet()) {
      i.dispose();
    }
    _images.clear();
    super.dispose();
  }
}
