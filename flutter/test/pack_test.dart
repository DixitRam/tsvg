// Smaller packages (tsvg pack default: TTF subsets via fontTools, big JPEG/PNG
// → WebP with paths rewritten in main.tsvg) play like --full packages: the
// Flutter painter renders both within 1% of pixels.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg_core.dart';
import 'package:tsvg/tsvg_io.dart';
import 'package:tsvg/src/flutter/media.dart';
import 'package:tsvg/src/flutter/painter.dart';

final String repo = Directory.current.parent.path; // flutter/ → repo root

Future<Uint8List> rgba(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a small pack (font subsets, WebP) renders like --full', (tester) async {
    await tester.runAsync(() async {
      final tmp = Directory.systemTemp.createTempSync('tsvg-pack');
      try {
        Future<(TsvgDoc, TsvgMedia, Map<String, Uint8List>)> pack(String name, List<String> flags) async {
          final out = '${tmp.path}/$name.tsvgz';
          final r = await Process.run('node', [
            '$repo/cli/tsvg.mjs',
            'pack',
            '$repo/examples/libs/report.tsvg',
            '-o',
            out,
            '--no-preview',
            ...flags,
          ]);
          expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
          final src = await openTsvgFile(out);
          final doc = parseTsvg(src.xml);
          final media = await TsvgMedia.load(doc, src);
          expect(media.errors, isEmpty, reason: '$name: ${media.errors.join('; ')}');
          return (doc, media, readZip(File(out).readAsBytesSync()));
        }

        // small first: its subset fonts must not stand in for the full ones
        final (sDoc, sMedia, sFiles) = await pack('small', const []);
        final (fDoc, fMedia, fFiles) = await pack('full', const ['--full']);
        // the small package really is the small one
        expect(sFiles.keys.where((p) => p.endsWith('.webp')), isNotEmpty);
        expect(fFiles.keys.where((p) => p.endsWith('.webp')), isEmpty);
        expect(sFiles['lib/_shared/fonts/Inter.ttf']!.length, lessThan(fFiles['lib/_shared/fonts/Inter.ttf']!.length));
        // same family + path, different bytes: the full fonts are registered apart from the subsets
        expect(sMedia.fontAliases, isEmpty);
        expect(fMedia.fontAliases.keys, containsAll(['Inter', 'JetBrains Mono']));

        for (final t in const [9.0, 14.0, 30.0]) {
          Future<Uint8List> frame(TsvgDoc doc, TsvgMedia media) async {
            final img = await renderTsvgImage(
              doc: doc,
              layout: doc.layout(null),
              t: t,
              options: defaultOptions(doc),
              media: media,
              width: 640,
            );
            final px = await rgba(img);
            img.dispose();
            return px;
          }

          final a = await frame(sDoc, sMedia);
          final b = await frame(fDoc, fMedia);
          expect(a.length, b.length);
          var off = 0;
          for (var i = 0; i < a.length; i += 4) {
            for (var k = 0; k < 3; k++) {
              if ((a[i + k] - b[i + k]).abs() > 40) {
                off++;
                break;
              }
            }
          }
          final ratio = off / (a.length ~/ 4);
          expect(ratio, lessThanOrEqualTo(0.01), reason: 't=$t: ${(ratio * 100).toStringAsFixed(2)}% pixels off');
        }
        sMedia.dispose();
        fMedia.dispose();
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
