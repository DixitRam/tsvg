// Widget tests for TsvgPlayer (audio disabled: no platform channels in tests).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg.dart';
import 'package:tsvg/tsvg_io.dart';

void main() {
  final demo = '${Directory.current.parent.path}/examples/demo/demo.tsvg';

  Future<TsvgPlayerController> mount(WidgetTester tester, Size size) async {
    final c = TsvgPlayerController(enableAudio: false);
    await tester.runAsync(() async => c.load(await openTsvgFile(demo)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: TsvgPlayer(controller: c),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return c;
  }

  double controlsOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('tsvg-controls'))).opacity;

  Rect playerRect(WidgetTester tester) => tester.getRect(find.byType(TsvgPlayer));

  // let pending tap / hide timers fire, stop the clock
  Future<void> settle(WidgetTester tester, TsvgPlayerController c) async {
    c.pause();
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('a tap shows the controls without pausing; they hide 3 s later', (tester) async {
    const phone = Size(390, 260);
    final c = await mount(tester, phone);
    expect(controlsOpacity(tester), 1); // paused: visible
    await c.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3200));
    expect(c.playing, isTrue);
    expect(controlsOpacity(tester), 0);

    // tap in the middle: controls come back, still playing
    await tester.tapAt(playerRect(tester).center + const Offset(0, -60));
    await tester.pump();
    expect(controlsOpacity(tester), 1);
    expect(c.playing, isTrue);
    // a second tap while shown hides them (still playing)
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(playerRect(tester).center + const Offset(0, -60));
    await tester.pump();
    expect(controlsOpacity(tester), 0);
    expect(c.playing, isTrue);
    await settle(tester, c);
  });

  testWidgets('double-tap on the right skips +10, on the left −10', (tester) async {
    final c = await mount(tester, const Size(390, 700));
    final r = playerRect(tester);
    final right = Offset(r.left + r.width * 0.85, r.top + r.height * 0.3);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(right);
    await tester.pump();
    expect(c.t, 10);
    expect(c.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    final left = Offset(r.left + r.width * 0.1, r.top + r.height * 0.3);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(left);
    await tester.pump();
    expect(c.t, 0);

    // while playing with the controls hidden, a double-tap skips and leaves them hidden
    await c.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3200));
    expect(controlsOpacity(tester), 0);
    final t0 = c.t;
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(right);
    await tester.pump();
    expect(c.t, closeTo(t0 + 10, 0.3));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controlsOpacity(tester), 0);
    await settle(tester, c);
  });

  testWidgets('centre ±10 and play buttons on narrow players', (tester) async {
    final c = await mount(tester, const Size(390, 700));
    await tester.tap(find.byKey(const ValueKey('tsvg-fwd')));
    await tester.pump();
    expect(c.t, 10);
    expect(find.text('· Zoom'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-play')));
    await tester.pump();
    expect(c.playing, isTrue);
    await settle(tester, c);
  });

  testWidgets('the speed button opens the speed menu; 1.5× sets the rate', (tester) async {
    final c = await mount(tester, const Size(960, 540));
    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-rate')));
    await tester.pump();
    expect(find.text('Playback speed'), findsOneWidget); // submenu header
    expect(find.text('Normal'), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(c.rate, 1.5);
    // wide: the popup goes back to the row list (speed row + bar button both say 1.5×)
    expect(find.text('1.5×'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('tsvg-menu-__rate')), findsOneWidget);
    // keyboard < > steps through the speeds
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.period, character: '>');
    await tester.pump();
    expect(c.rate, 1.75);

    // narrow: Settings → Playback speed → 0.5×, the bottom sheet closes on pick
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 390, height: 700, child: TsvgPlayer(controller: c)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('tsvg-rate')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tsvg-settings')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tsvg-menu-__rate')));
    await tester.pump();
    await tester.tap(find.text('0.5×'));
    await tester.pump();
    expect(c.rate, 0.5);
    expect(find.byKey(const ValueKey('tsvg-menu-__rate')), findsNothing);
    await tester.binding.setSurfaceSize(null);
    await settle(tester, c);
  });

  testWidgets('mute and volume set the master gain', (tester) async {
    final c = await mount(tester, const Size(960, 540));
    expect(c.gain, 1);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-mute')));
    await tester.pump();
    expect(c.muted, isTrue);
    expect(c.gain, 0);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(c.gain, 1);
    // ↓ twice: 0.8
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.gain, closeTo(0.8, 1e-9));

    // hovering the mute button opens the slider; dragging it to the left end = 0
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byKey(const ValueKey('tsvg-mute'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final slider = find.byKey(const ValueKey('tsvg-volume'));
    expect(slider, findsOneWidget);
    await tester.tapAt(tester.getRect(slider).centerLeft + const Offset(9, 0));
    await tester.pump();
    expect(c.gain, lessThan(0.05));
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();
    expect(c.gain, closeTo(0.5, 0.1));
    expect(c.muted, isFalse);
    await mouse.removePointer();
    await settle(tester, c);
  });

  testWidgets('the settings menu changes a document option, captions and layout', (tester) async {
    final c = await mount(tester, const Size(960, 540));
    c.seek(2);
    await tester.pump();
    expect(find.textContaining('This is a TSVG video'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-settings')));
    await tester.pump();
    expect(find.text('Playback speed'), findsOneWidget);
    expect(find.text('Captions'), findsOneWidget);
    expect(find.text('Layout'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-menu-lang')));
    await tester.pump();
    await tester.tap(find.text('ગુજરાતી'));
    await tester.pump();
    expect(c.options['lang'], 'gu');
    expect(find.textContaining('આ TSVG વિડિયો છે'), findsOneWidget);
    // back on the row list: the row shows the new choice
    expect(find.text('ગુજરાતી'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tsvg-menu-__layout')));
    await tester.pump();
    await tester.tap(find.text('portrait · 1080×1920'));
    await tester.pump();
    expect(c.layoutPref, 'portrait');
    await tester.tap(find.byKey(const ValueKey('tsvg-menu-__cc')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tsvg-choice-__cc-off')));
    await tester.pump();
    expect(c.captions, isFalse);
    // Escape closes the menu
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('tsvg-menu-lang')), findsNothing);
    await settle(tester, c);
  });

  testWidgets('Chapters is the first settings row; picking one seeks to it', (tester) async {
    final c = await mount(tester, const Size(960, 540));
    final chs = c.tl!.chapters;
    expect(chs.length, greaterThan(2));
    await tester.tap(find.byKey(const ValueKey('tsvg-settings')));
    await tester.pump();
    final row = find.byKey(const ValueKey('tsvg-menu-__chapter'));
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('tsvg-menu-__rate'))).dy));
    await tester.tap(row);
    await tester.pump();
    // m:ss  label per chapter, the current (first) one checked
    expect(find.text('0:00  ${c.label(chs[0].label)}'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('tsvg-choice-__chapter-0')), matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('tsvg-choice-__chapter-2')));
    await tester.pump();
    expect(c.t, chs[2].t);
    expect(c.chapterAt(c.t), chs[2]);
    await settle(tester, c);
  });

  testWidgets('keys, zoom chip and mouse click', (tester) async {
    final c = await mount(tester, const Size(960, 540));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(c.t, 10);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(c.t, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump();
    expect(c.t, closeTo(24.5, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(c.captions, isFalse);

    c.zoomAt(3, const Offset(100, 50));
    expect(c.pan, const Offset(-200, -100));
    await tester.pump();
    expect(find.text('Zoom 3.0× · tap to reset'), findsOneWidget);
    await tester.tap(find.text('Zoom 3.0× · tap to reset'));
    await tester.pump();
    expect(c.zoom, 1);

    // mouse click plays (after the double-click window)
    final r = playerRect(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: r.topLeft + const Offset(200, 120));
    await mouse.down(r.topLeft + const Offset(200, 120));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 250));
    expect(c.playing, isTrue);
    final t0 = c.t;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.t, greaterThan(t0));
    await mouse.removePointer();
    await settle(tester, c);
  });

  testWidgets('controls: false draws frames only', (tester) async {
    final c = TsvgPlayerController(enableAudio: false);
    await tester.runAsync(() async => c.load(await openTsvgFile(demo)));
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(width: 400, height: 300, child: TsvgPlayer(controller: c, controls: false)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('tsvg-controls')), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
    c.dispose();
  });

  testWidgets('auto layout picks the closest aspect ratio', (tester) async {
    final c = TsvgPlayerController(enableAudio: false);
    await tester.runAsync(() async => c.load(await openTsvgFile(demo)));
    expect(c.layoutFor(const Size(400, 800)).id, 'portrait');
    expect(c.layoutFor(const Size(800, 400)).id, 'landscape');
    c.dispose();
  });
}
