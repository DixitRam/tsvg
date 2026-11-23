// Smoke test over the 60 style videos in ../examples/styles: every document
// parses, loads its media, renders the catalog thumbnail frame (thumbT) in each
// layout without throwing. Writes test/out/styles/<id>.png and styles.md.
// Skipped when examples/styles is not there.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg_core.dart';
import 'package:tsvg/tsvg_io.dart';
import 'package:tsvg/src/flutter/media.dart';
import 'package:tsvg/src/flutter/painter.dart';

final String repo = Directory.current.parent.path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory('$repo/examples/styles/catalog');
  testWidgets('style videos render their thumbnail frame', (tester) async {
    final out = Directory('test/out/styles')..createSync(recursive: true);
    final problems = <String>[];
    final diffs = <String, double>{}; // vs the web thumbnail (JPEG), informational
    var n = 0;
    await tester.runAsync(() async {
      final metas = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in metas) {
        final meta = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final id = meta['id'] as String;
        final t = (meta['thumbT'] as num?)?.toDouble() ?? 0;
        n++;
        try {
          final src = await openTsvgFile('$repo/examples/styles/$id.tsvg');
          final v = validate(src.xml, has: src.has, samples: 1);
          if (!v.ok) problems.add('$id: validate: ${v.errors.take(3).join('; ')}');
          final doc = parseTsvg(src.xml);
          final media = await TsvgMedia.load(doc, src);
          if (media.errors.isNotEmpty) problems.add('$id: media: ${media.errors.join('; ')}');
          final thumb = File('$repo/examples/styles/thumbs/$id.jpg');
          if (thumb.existsSync()) {
            final g = (await TsvgMedia.decode(thumb.readAsBytesSync()))!;
            final l = doc.layouts.firstWhere((l) => (l.w > l.h) == (g.width > g.height), orElse: () => doc.layouts.first);
            final img = await renderTsvgImage(doc: doc, layout: l, t: t, options: defaultOptions(doc), media: media, width: g.width);
            if (img.height == g.height) {
              final a = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
              final b = (await g.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
              var off = 0;
              for (var i = 0; i < a.length; i += 4) {
                var d = 0;
                for (var k = 0; k < 3; k++) {
                  final x = (a[i + k] - b[i + k]).abs();
                  if (x > d) d = x;
                }
                if (d > 40) off++;
              }
              diffs[id] = off / (a.length / 4);
            }
            img.dispose();
            g.dispose();
          }
          for (final l in doc.layouts) {
            final img = await renderTsvgImage(doc: doc, layout: l, t: t, options: defaultOptions(doc), media: media, width: 480);
            final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
            File('${out.path}/$id-${l.id}.png').writeAsBytesSync(png);
            img.dispose();
          }
        } catch (e) {
          problems.add('$id: $e');
        }
      }
    });
    final worst = diffs.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    String pct(double v) => '${(v * 100).toStringAsFixed(2)}%';
    File('${out.path}/styles.md').writeAsStringSync([
      '# Style videos (thumbT frame per layout)',
      '',
      '$n documents, ${problems.length} problem(s)',
      ...problems.map((p) => '- $p'),
      '',
      'Pixels off (> 40/255) vs the web thumbnail JPEG (lossy, so a few % is noise), worst first:',
      '',
      '| style | pixels off |',
      '|---|---|',
      for (final e in worst) '| ${e.key} | ${pct(e.value)} |',
    ].join('\n'));
    // ignore: avoid_print
    print('styles: $n documents, ${problems.length} problem(s)\n${problems.join('\n')}\n'
        'worst vs thumbs: ${worst.take(8).map((e) => '${e.key} ${pct(e.value)}').join(', ')}');
    expect(problems, isEmpty);
  }, skip: !dir.existsSync());
}
