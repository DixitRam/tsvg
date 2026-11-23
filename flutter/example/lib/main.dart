// TSVG example: plays the demo package (assets/demo.tsvgz, built with
// `node cli/tsvg.mjs pack examples/demo/demo.tsvg -o flutter/example/assets/demo.tsvgz`).
//
// Query parameters on web: ?lang=gu&theme=light&mix=speech&t=12 (initial state).
import 'package:flutter/material.dart';
import 'package:tsvg/tsvg.dart';

void main() => runApp(const TsvgExampleApp());

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
    await controller.load(await openTsvgAsset('assets/demo.tsvgz'));
    if (t != null) controller.seek(t);
    // ?autoplay=1 on web, --dart-define=TSVG_AUTOPLAY=true elsewhere
    if (Uri.base.queryParameters['autoplay'] == '1' || const bool.fromEnvironment('TSVG_AUTOPLAY')) {
      await controller.play();
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
