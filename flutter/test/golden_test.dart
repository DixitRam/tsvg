// Conformance: render every case in ../tests/cases.json with Flutter and
// compare it with the web golden (headless Chrome) in ../tests/golden.
//
// Writes test/out/<case>.png, test/out/<case>.diff.png and test/out/report.md.
// Metric (same as the web harness): a pixel is "off" when any channel differs
// by more than 40/255. Text rasterisation differs between Skia-in-flutter_tester
// and Chrome, so the threshold is a per-case budget, not pixel equality.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg_core.dart';
import 'package:tsvg/tsvg_io.dart';
import 'package:tsvg/src/flutter/media.dart';
import 'package:tsvg/src/flutter/painter.dart';

/// Max share of pixels off by > 40/255 for a case to pass.
const double maxOffRatio = 0.02;

final String repo = Directory.current.parent.path; // flutter/ → repo root

Future<void> loadSystemFont(String family, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  await loader.load();
}

Future<Uint8List> rgba(ui.Image img) async => (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = (jsonDecode(File('$repo/tests/cases.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final outDir = Directory('test/out')..createSync(recursive: true);
  final rows = <String>[];
  final results = <String, double>{};

  testWidgets('golden frames vs web', (tester) async {
    await tester.runAsync(() async {
      // the web goldens come from Chrome on macOS: monospace = Menlo, emoji = Apple Color Emoji
      await loadSystemFont('Menlo', '/System/Library/Fonts/Menlo.ttc');
      await loadSystemFont('Apple Symbols', '/System/Library/Fonts/Apple Symbols.ttf');
      await loadSystemFont('Apple Color Emoji', '/System/Library/Fonts/Apple Color Emoji.ttc');
      final sources = <String, (TsvgDoc, TsvgMedia)>{};
      for (final c in cases) {
        // cases the web draws with real video frames: Flutter's painter only draws posters
        if (((c['skip'] as List?) ?? const []).contains('flutter')) {
          // ignore: avoid_print
          print('skip ${c['name']}: not a Flutter case (skip: ${c['skip']})');
          rows.add('| ${c['name']} | skipped (flutter) | | |');
          continue;
        }
        final file = c['file'] as String;
        if (!sources.containsKey(file)) {
          // documents with imports: play the flattened package, as players do (tsvg pack flattens)
          var path = '$repo/$file';
          if (File(path).readAsStringSync().contains('<import')) {
            final out = '${outDir.path}/${file.split('/').last}z';
            final r = await Process.run('node', ['$repo/cli/tsvg.mjs', 'pack', path, '-o', out, '--no-preview']);
            expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
            path = out;
          }
          final src = await openTsvgFile(path);
          final doc = parseTsvg(src.xml);
          final media = await TsvgMedia.load(doc, src);
          expect(media.errors, isEmpty, reason: media.errors.join('; '));
          sources[file] = (doc, media);
        }
        final (doc, media) = sources[file]!;
        final layout = doc.layout(c['layout'] as String?);
        final opts = {...defaultOptions(doc), ...((c['opts'] as Map?) ?? {}).cast<String, String>()};
        final width = (c['width'] as num?)?.toInt() ?? 480;
        final img = await renderTsvgImage(doc: doc, layout: layout, t: (c['t'] as num).toDouble(), options: opts, media: media, width: width);
        final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        final name = c['name'] as String;
        File('${outDir.path}/$name.png').writeAsBytesSync(png);
        final mine = await rgba(img);

        final goldBytes = File('$repo/tests/golden/$name.png').readAsBytesSync();
        final gold = await TsvgMedia.decode(goldBytes);
        if (gold!.width != img.width || gold.height != img.height) {
          rows.add('| $name | size mismatch ${gold.width}x${gold.height} vs ${img.width}x${img.height} | | |');
          results[name] = 1;
          continue;
        }
        final ref = await rgba(gold);
        var off = 0;
        var sum = 0;
        final diff = Uint8List(mine.length);
        for (var i = 0; i < mine.length; i += 4) {
          var d = 0;
          for (var k = 0; k < 3; k++) {
            final x = (mine[i + k] - ref[i + k]).abs();
            sum += x;
            if (x > d) d = x;
          }
          final bad = d > 40;
          if (bad) off++;
          diff[i] = bad ? 255 : (mine[i] * 0.3).round();
          diff[i + 1] = bad ? 0 : (mine[i + 1] * 0.3).round();
          diff[i + 2] = bad ? 80 : (mine[i + 2] * 0.3).round();
          diff[i + 3] = 255;
        }
        final px = mine.length ~/ 4;
        final ratio = off / px;
        final mean = sum / (px * 3);
        results[name] = ratio;
        rows.add('| $name | ${(ratio * 100).toStringAsFixed(2)}% | ${mean.toStringAsFixed(2)} | ${ratio <= maxOffRatio ? 'pass' : 'FAIL'} |');
        final buf = await ui.ImmutableBuffer.fromUint8List(diff);
        final desc = ui.ImageDescriptor.raw(buf, width: img.width, height: img.height, pixelFormat: ui.PixelFormat.rgba8888);
        final codec = await desc.instantiateCodec();
        final dimg = (await codec.getNextFrame()).image;
        File('${outDir.path}/$name.diff.png')
            .writeAsBytesSync((await dimg.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
        img.dispose();
        gold.dispose();
      }
    });
    final report = [
      '# Flutter vs web goldens',
      '',
      'Pixels off = any channel differs by > 40/255. Budget per case: ${(maxOffRatio * 100).toStringAsFixed(1)}%.',
      '',
      '| case | pixels off | mean abs diff (0-255) | result |',
      '|---|---|---|---|',
      ...rows,
    ].join('\n');
    File('${outDir.path}/report.md').writeAsStringSync('$report\n');
    // ignore: avoid_print
    print(report);
    for (final e in results.entries) {
      expect(e.value, lessThanOrEqualTo(maxOffRatio), reason: '${e.key}: ${(e.value * 100).toStringAsFixed(2)}% pixels off');
    }
  });
}
