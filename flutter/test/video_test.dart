// <video> (TSVG 0.8): the painter draws posters from a packed document, the
// frame reports its clip nodes, and the player keeps one platform video per
// clip node in sync (checked against a fake VideoPlayerPlatform).
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsvg/tsvg.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

final String repo = Directory.current.parent.path;

class FakeVideoPlatform extends VideoPlayerPlatform {
  final log = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  var _next = 1;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    final sc = _events[id] = StreamController<VideoEvent>();
    sc.add(VideoEvent(eventType: VideoEventType.initialized, duration: const Duration(seconds: 10), size: const Size(640, 360)));
    log.add('create $id');
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async => log.add('dispose $playerId');
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async => log.add('play $playerId');
  @override
  Future<void> pause(int playerId) async => log.add('pause $playerId');
  @override
  Future<void> setVolume(int playerId, double volume) async => log.add('volume $playerId $volume');
  @override
  Future<void> seekTo(int playerId, Duration position) async => log.add('seek $playerId ${position.inMilliseconds}');
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async => log.add('speed $playerId $speed');
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => ColoredBox(key: ValueKey('fake-video-${options.playerId}'), color: Colors.red);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Directory('test/out')..createSync(recursive: true);
  final pkg = '${out.path}/video.tsvgz';

  setUpAll(() {
    final r = Process.runSync('node', ['$repo/cli/tsvg.mjs', 'pack', '$repo/examples/video/video.tsvg', '-o', pkg, '--no-preview']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  Future<(TsvgSource, TsvgDoc, TsvgMedia)> open() async {
    final src = packageSource(File(pkg).readAsBytesSync());
    final doc = parseTsvg(src.xml);
    final media = await TsvgMedia.load(doc, src);
    expect(media.errors, isEmpty, reason: media.errors.join('; '));
    return (src, doc, media);
  }

  testWidgets('packed example: the poster shows at t=3 (not a grey box)', (tester) async {
    await tester.runAsync(() async {
      final (_, doc, media) = await open();
      expect(doc.assets['fractal']!.poster, 'clips/fractal.poster.jpg');
      expect(doc.assets['fractal']!.dur, 8);
      expect(media.image('clips/fractal.poster.jpg'), isNotNull);
      final layout = doc.layout('landscape');
      final opts = defaultOptions(doc);
      final png = await renderTsvgPng(doc: doc, layout: layout, t: 3, options: opts, media: media, width: 960);
      File('${out.path}/video-poster.png').writeAsBytesSync(png);
      final img = await renderTsvgImage(doc: doc, layout: layout, t: 3, options: opts, media: media, width: 480);
      final grey = await renderTsvgImage(doc: doc, layout: layout, t: 3, options: opts, width: 480); // no media: grey box
      final a = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final b = (await grey.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      // the middle of the frame (above the caption bar) is the clip
      var differ = 0, total = 0;
      for (var y = 40; y < 140; y++) {
        for (var x = 80; x < 400; x++) {
          final i = (y * 480 + x) * 4;
          total++;
          if ((a[i] - b[i]).abs() > 40 || (a[i + 1] - b[i + 1]).abs() > 40 || (a[i + 2] - b[i + 2]).abs() > 40) differ++;
        }
      }
      // ignore: avoid_print
      print('poster vs grey box: ${(differ * 100 / total).toStringAsFixed(1)}% of the centre differs → test/out/video-poster.png');
      expect(differ / total, greaterThan(0.5));
      final c = ((90 * 480) + 240) * 4;
      expect([b[c], b[c + 1], b[c + 2]], everyElement(lessThan(60)), reason: 'without media: the dim grey box');
    });
  });

  testWidgets('the frame reports each clip node: clip time, box, transform', (tester) async {
    await tester.runAsync(() async {
      final (_, doc, media) = await open();
      final layout = doc.layout('landscape');
      final opts = defaultOptions(doc);
      const size = Size(640, 360);
      final a = collectTsvgVideos(size, doc: doc, layout: layout, t: 3, options: opts, media: media);
      expect(a, hasLength(1));
      expect(a.first.req.ct, closeTo(3, 1e-9));
      expect([a.first.req.w, a.first.req.h, a.first.req.fit], [layout.w, layout.h, 'cover'], reason: 'w=W h=H');
      expect(a.first.transform[0], closeTo(640 / layout.w, 1e-6), reason: 'layout → widget scale');
      final tl = forOptions(doc, opts);
      final frames = tl.scenes.firstWhere((s) => s.id == 'frames');
      final T = 3.0; // 3 s into the second scene
      final b = collectTsvgVideos(size, doc: doc, layout: layout, t: frames.start + T, options: opts, media: media);
      expect(b, hasLength(2));
      expect(b[0].req.ct, closeTo(2 + (T - 0.4), 1e-9), reason: 'start=2, col at=0.4');
      expect(b[1].req.ct, closeTo((T - 0.9) * 0.5, 1e-9), reason: 'rate=0.5, col at=0.9');
      expect([b[0].req.r, b[1].req.rate], [24, 0.5]);
      expect(b[0].transform[1].abs(), lessThan(1e-9));
      expect(b[1].transform[1].abs(), greaterThan(0.01), reason: 'rot=-3 is in the transform');
      expect(b[0].req.key, isNot(b[1].req.key));
    });
  });

  testWidgets('player: overlays a synced VideoPlayer per clip node', (tester) async {
    final fake = FakeVideoPlatform();
    VideoPlayerPlatform.instance = fake;
    final c = TsvgPlayerController(enableAudio: false);
    final src = packageSource(File(pkg).readAsBytesSync());
    await tester.runAsync(() => c.load(src));
    expect(c.videos, isNotNull);
    c.seek(3);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 640, height: 360, child: TsvgPlayer(controller: c, controls: false)))),
    ));
    // the clip opens (temp file + platform create + initialized), then the next frame seeks it
    for (var i = 0; i < 50 && find.byType(VideoPlayer).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(fake.log, contains('seek 1 3000'), reason: 'paused: seek to the clip time');
    expect(fake.log.where((l) => l.startsWith('play')), isEmpty);
    final box = tester.getRect(find.byKey(const ValueKey('fake-video-1')));
    expect(box.width, closeTo(640, 1), reason: 'cover-fitted 640×360 clip fills the frame');

    // playing at 1.5×: clips play at rate × speed
    c.setRate(1.5);
    fake.log.clear();
    await tester.runAsync(() => c.play());
    await tester.pump();
    expect(fake.log, containsAllInOrder(['seek 1 3000', 'play 1']));
    expect(fake.log, contains('speed 1 1.5'));
    c.pause();
    await tester.pump();
    expect(fake.log.last, startsWith('pause 1'));

    // second scene: two nodes of the same file → two players, the first clip (off screen) stays paused
    final frames = forOptions(c.doc!, c.options).scenes.firstWhere((s) => s.id == 'frames');
    c.seek(frames.start + 3);
    for (var i = 0; i < 50 && find.byType(VideoPlayer).evaluate().length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(VideoPlayer), findsNWidgets(2));
    expect(fake.log, containsAll(['seek 2 4600', 'seek 3 1050']));
    fake.log.clear();
    await tester.runAsync(() => c.play());
    await tester.pump();
    expect(fake.log, containsAll(['speed 2 1.5', 'speed 3 0.75', 'play 2', 'play 3']));
    expect(fake.log, isNot(contains('play 1')));
    c.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
