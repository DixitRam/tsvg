// Widget tests for TsvgPlayer (audio disabled: no platform channels in tests).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg.dart';
import 'package:tsvg/tsvg_io.dart';

void main() {
  final demo = '${Directory.current.parent.path}/examples/demo/demo.tsvg';

  testWidgets('player loads, seeks, skips, changes options and zooms', (tester) async {
    final c = TsvgPlayerController(enableAudio: false);
    await tester.runAsync(() async => c.load(await openTsvgFile(demo)));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 960, height: 540, child: TsvgPlayer(controller: c)))),
    ));
    await tester.pump();
    expect(c.ready, isTrue);
    expect(find.text('0:00 / 0:49'), findsOneWidget);

    // tap the forward-10 button
    await tester.tap(find.byIcon(Icons.forward_10_rounded).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.t, 10);
    expect(find.text('• Zoom'), findsOneWidget);

    // keyboard: j = back 10 s, digit = seek to 10 %
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.t, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump();
    expect(c.t, closeTo(24.5, 1e-9));

    // captions follow the say lines
    c.seek(2);
    await tester.pump();
    expect(find.textContaining('This is a TSVG video'), findsOneWidget);

    // options panel → Gujarati
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pump();
    expect(find.text('LANGUAGE'), findsOneWidget);
    expect(find.text('LAYOUT (PLAYER)'), findsOneWidget);
    await tester.tap(find.text('ગુજરાતી'));
    await tester.pump();
    expect(c.options['lang'], 'gu');
    expect(find.textContaining('આ TSVG વિડિયો છે'), findsOneWidget);
    await tester.tap(find.text('portrait 1080×1920'));
    await tester.pump();
    expect(c.layoutPref, 'portrait');

    // zoom keeps the focus point; double-tap in the middle resets
    c.zoomAt(3, const Offset(100, 50));
    expect(c.pan, const Offset(-200, -100));
    await tester.pump();
    expect(find.textContaining('zoom 3.0×'), findsOneWidget);
    c.resetZoom();

    // playing advances the clock
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tester.pump();
    final t0 = c.t;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.playing, isTrue);
    expect(c.t, greaterThan(t0));
    c.pause();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('auto layout picks the closest aspect ratio', (tester) async {
    final c = TsvgPlayerController(enableAudio: false);
    await tester.runAsync(() async => c.load(await openTsvgFile(demo)));
    expect(c.layoutFor(const Size(400, 800)).id, 'portrait');
    expect(c.layoutFor(const Size(800, 400)).id, 'landscape');
    c.dispose();
  });
}
