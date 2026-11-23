// TSVG example: plays the demo package (assets/demo.tsvgz, built with
// `node cli/tsvg.mjs pack examples/demo/demo.tsvg -o flutter/example/assets/demo.tsvgz`).
//
// Query parameters on web: ?lang=gu&theme=light&mix=speech&t=12 (initial state).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsvg/tsvg.dart';

void main() {
  // --dart-define=TSVG_AUDIO_LOG=true prints audio starts, resyncs and drift stats
  TsvgAudioEngine.log = const bool.fromEnvironment('TSVG_AUDIO_LOG');
  runApp(const TsvgExampleApp());
}

class TsvgExampleApp extends StatelessWidget {
  const TsvgExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TSVG player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const DemoPage(),
      );
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});
  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  late final TsvgPlayerController controller;
  Map<String, String> opts = {};

  @override
  void initState() {
    super.initState();
    final q = Uri.base.queryParameters;
    controller = TsvgPlayerController(options: {
      for (final k in ['lang', 'theme', 'mix'])
        if (q[k] != null) k: q[k]!,
    });
    if (q['layout'] != null) controller.layoutPref = q['layout']!;
    _open(double.tryParse(q['t'] ?? ''));
  }

  Future<void> _open(double? t) async {
    // iOS AVPlayer cannot decode Ogg: use the same demo with m4a clips there
    // (built with ffmpeg -c:a aac from examples/demo). --dart-define=TSVG_ASSET=… overrides.
    const forced = String.fromEnvironment('TSVG_ASSET');
    final asset = forced.isNotEmpty
        ? forced
        : 'assets/demo.tsvgz';
    await controller.load(await openTsvgAsset(asset));
    if (t != null) controller.seek(t);
    // ?autoplay=1 on web, --dart-define=TSVG_AUTOPLAY=true elsewhere
    // ?rate=1.5 on web, --dart-define=TSVG_RATE=1.5 elsewhere
    final rate = double.tryParse(Uri.base.queryParameters['rate'] ?? const String.fromEnvironment('TSVG_RATE'));
    if (rate != null) controller.setRate(rate);
    if (Uri.base.queryParameters['autoplay'] == '1' || const bool.fromEnvironment('TSVG_AUTOPLAY')) {
      await controller.play();
    }
    if (TsvgAudioEngine.log) {
      Timer.periodic(const Duration(seconds: 5), (_) {
        if (controller.playing) debugPrint('tsvg audio stats t=${controller.t.toStringAsFixed(1)} ${controller.audioStats}');
      });
    }
    if (mounted) setState(() => opts = controller.options);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = controller.doc;
    return Scaffold(
      backgroundColor: const Color(0xff0b0d12),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('TSVG · Flutter engine', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              doc == null
                  ? 'loading…'
                  : '${doc.duration.round()} s · ${doc.scenes.length} scenes · ${doc.layouts.length} layouts × '
                      '${optionCombos(doc).length} option sets · options: ${opts.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
              style: const TextStyle(color: Color(0x99ffffff), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TsvgPlayer(
                controller: controller,
                onOptions: (o) => setState(() => opts = Map.of(o)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
