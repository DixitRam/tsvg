// Where a document and its files come from: a .tsvgz package (zip with
// main.tsvg at the root) or any path → bytes callback (directory, assets, HTTP).
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'js.dart';

const String tsvgMain = 'main.tsvg';

abstract class TsvgSource {
  /// The XML of the document.
  String get xml;

  /// Bytes of a file the document references (relative path), or null.
  Future<Uint8List?> read(String path);

  /// Whether the file exists (best effort; used by validate).
  bool has(String path);
}

/// In-memory files (e.g. an unpacked .tsvgz).
class TsvgMapSource implements TsvgSource {
  TsvgMapSource(this.xml, this.files);
  @override
  final String xml;
  final Map<String, Uint8List> files;
  @override
  Future<Uint8List?> read(String path) async => files[_norm(path)];
  @override
  bool has(String path) => files.containsKey(_norm(path));
}

/// Files fetched on demand (asset bundle, file system, network).
class TsvgCallbackSource implements TsvgSource {
  TsvgCallbackSource(this.xml, this.reader, {bool Function(String)? exists}) : _exists = exists;
  @override
  final String xml;
  final Future<Uint8List?> Function(String path) reader;
  final bool Function(String)? _exists;
  final Map<String, Future<Uint8List?>> _cache = {};
  @override
  Future<Uint8List?> read(String path) => _cache[_norm(path)] ??= reader(_norm(path));
  @override
  bool has(String path) => _exists?.call(_norm(path)) ?? true;
}

String _norm(String p) => p.startsWith('./') ? p.substring(2) : p;

/// True when [b] starts with a zip local-file header.
bool isZip(List<int> b) => b.length > 4 && b[0] == 0x50 && b[1] == 0x4b && b[2] == 3 && b[3] == 4;

/// Reads a .tsvgz package → path → bytes. Throws [TsvgError].
Map<String, Uint8List> readZip(Uint8List bytes) {
  final Archive arc;
  try {
    arc = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw TsvgError('not a zip file (.tsvgz): $e');
  }
  final files = <String, Uint8List>{};
  for (final f in arc.files) {
    if (!f.isFile || f.name.endsWith('/')) continue;
    files[f.name] = f.content;
  }
  if (!files.containsKey(tsvgMain)) throw TsvgError('package has no $tsvgMain');
  return files;
}

/// Writes a .tsvgz package (main.tsvg first; text files deflated).
Uint8List writeZip(Map<String, List<int>> entries) {
  final arc = Archive();
  final names = entries.keys.toList()..sort((a, b) => a == tsvgMain ? -1 : (b == tsvgMain ? 1 : a.compareTo(b)));
  for (final n in names) {
    final data = Uint8List.fromList(entries[n]!);
    final f = ArchiveFile(n, data.length, data);
    if (!RegExp(r'\.(tsvg|xml|json|svg|txt|vtt|ttf|otf)$', caseSensitive: false).hasMatch(n)) {
      f.compression = CompressionType.none;
    }
    arc.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(arc));
}

/// A source from .tsvgz bytes.
TsvgMapSource packageSource(Uint8List bytes) {
  final files = readZip(bytes);
  return TsvgMapSource(utf8.decode(files[tsvgMain]!), files);
}
