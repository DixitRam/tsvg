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

  /// Fonts registered with the engine: family → content key → engine family.
  /// Packages may ship different files under the same family and path (e.g.
  /// `tsvg pack` font subsets), so fonts are registered by content: the first
  /// file of a family keeps its name, other files get `family#key`.
  static final Map<String, Map<String, String>> _registered = {};

  /// Document family → engine family, for this document's fonts registered
  /// under another name (see [_registered]).
  final Map<String, String> fontAliases = {};

  /// The engine family for [family] in this document.
  String font(String family) => fontAliases[family] ?? family;

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
      byFamily.putIfAbsent(f.family, () => []).add(f);
    }
    for (final e in byFamily.entries) {
      final files = <Uint8List>[];
      for (final f in e.value) {
        final bytes = await source.read(f.src!);
        if (bytes == null) {
          errors.add('font ${f.family}: ${f.src} not found');
          continue;
        }
        files.add(bytes);
      }
      if (files.isEmpty) continue;
      final key = _fontKey(files);
      final known = _registered.putIfAbsent(e.key, () => {});
      var name = known[key];
      if (name == null) {
        name = known.isEmpty ? e.key : '${e.key}#$key';
        known[key] = name;
        final loader = FontLoader(name);
        for (final b in files) {
          loader.addFont(Future.value(ByteData.sublistView(b)));
        }
        try {
          await loader.load();
        } catch (err) {
          errors.add('font ${e.key}: $err');
        }
      }
      if (name != e.key) fontAliases[e.key] = name;
    }
  }

  // FNV-1a over every file of a family + the lengths
  static String _fontKey(List<Uint8List> files) {
    var h = 0x811c9dc5;
    for (final b in files) {
      for (final x in b) {
        h = ((h ^ x) * 0x01000193) & 0xffffffff;
      }
      h = ((h ^ b.length) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(36);
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
