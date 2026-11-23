// Loading a document from the asset bundle, bytes or a URL.
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/source.dart';

/// Opens a .tsvg or .tsvgz from the asset bundle. For a .tsvg, referenced
/// files resolve relative to its asset directory.
Future<TsvgSource> openTsvgAsset(String key, {AssetBundle? bundle}) async {
  final b = bundle ?? rootBundle;
  final data = await b.load(key);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (isZip(bytes)) return packageSource(Uint8List.fromList(bytes));
  final slash = key.lastIndexOf('/');
  final dir = slash < 0 ? '' : key.substring(0, slash + 1);
  return TsvgCallbackSource(utf8.decode(bytes), (p) async {
    try {
      final d = await b.load('$dir$p');
      return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    } catch (_) {
      return null;
    }
  });
}

/// Opens .tsvg / .tsvgz bytes. [resolve] fetches referenced files for a bare .tsvg.
TsvgSource openTsvgBytes(Uint8List bytes, {Future<Uint8List?> Function(String path)? resolve}) {
  if (isZip(bytes)) return packageSource(bytes);
  return TsvgCallbackSource(utf8.decode(bytes), resolve ?? (_) async => null);
}
