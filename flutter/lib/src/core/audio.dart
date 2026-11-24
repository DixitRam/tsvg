// Audio plan: everything an engine needs to play sound for one option set.
import 'expr.dart';
import 'js.dart';
import 'model.dart';
import 'render.dart';

/// A spoken line (caption + optional recorded clip).
class SayLine {
  SayLine({
    required this.key,
    required this.start,
    required this.dur,
    required this.text,
    required this.speak,
    required this.clip,
    required this.lang,
    this.voice,
  });
  final String key;
  final double start;
  double dur;
  final String text, speak;
  final String? clip;
  final String? lang;
  final String? voice;
  double get end => start + dur;
  @override
  String toString() => 'SayLine($key @$start +$dur "$text" clip=$clip)';
}

class AudioPlan {
  const AudioPlan(this.mix, this.clips);

  /// Bus gains (voice, music, sfx, …).
  final Map<String, double> mix;
  final List<TsvgAudio> clips;
}

List<SayLine> sayLines(TsvgDoc doc, Map<String, String> opts) {
  doc = forOptions(doc, opts);
  final env = makeEnv(doc, opts, doc.layouts.first, 0);
  final lang = opts['lang'];
  final out = <SayLine>[];
  for (final s in doc.says) {
    final when = s.raw['when'];
    if (when != null && when.isNotEmpty && !truthy(compiled(when.replaceFirst(RegExp(r'^='), ''))(env))) continue;
    final text = toStr(value(s.raw['text'], env, doc));
    final baked = doc.voices['${s.key}|$lang'];
    final srcLang = s.raw['src.$lang'];
    final clip = (srcLang != null && srcLang.isNotEmpty) ? srcLang : (baked?.src != null && baked!.src!.isNotEmpty ? baked.src : null);
    final dur = lineDur(doc, s.key, s.raw, lang, env);
    final sp = (s.raw['speak.$lang'] ?? '').isNotEmpty ? s.raw['speak.$lang'] : s.raw['speak'];
    out.add(SayLine(
      key: s.key,
      start: s.start,
      dur: dur,
      text: text,
      speak: sp != null && sp.isNotEmpty ? toStr(value(sp, env, doc)) : text,
      clip: clip,
      lang: lang,
      voice: s.raw['voice'],
    ));
  }
  return out;
}

AudioPlan audioPlan(TsvgDoc doc, Map<String, String> opts) {
  doc = forOptions(doc, opts);
  final env = makeEnv(doc, opts, doc.layouts.first, 0);
  final mix = doc.mixes[opts['mix']] ?? const {'voice': 1.0, 'music': 1.0, 'sfx': 1.0};
  final clips = <TsvgAudio>[
    for (final a in doc.audio)
      if (a.when == null || a.when!.isEmpty || truthy(compiled(a.when!.replaceFirst(RegExp(r'^='), ''))(env))) a.copy(),
  ];
  for (final l in sayLines(doc, opts)) {
    if (l.clip != null) clips.add(TsvgAudio(bus: 'voice', src: l.clip, start: l.start, vol: 1));
  }
  return AudioPlan(mix, clips);
}

/// Asset id or path → path inside the package.
String? assetPath(TsvgDoc doc, String? ref) => ref != null && doc.assets.containsKey(ref) ? doc.assets[ref]!.src : ref;

/// Ducking (0.9): `<mix … duck="0.35">` lowers the music bus to duck× while a
/// line is spoken, with 0.25 s ramps either side. The factor at time [t]
/// (1 = no ducking); players apply it to the music bus. [lines] defaults to
/// [sayLines] for [opts].
double duckAt(TsvgDoc doc, Map<String, String> opts, double t, [List<SayLine>? lines]) {
  final d = doc.mixes[opts['mix']]?['duck'];
  if (d == null || d >= 1) return 1;
  var k = 0.0;
  const ramp = 0.25;
  for (final l in lines ?? sayLines(doc, opts)) {
    if (l.clip == null && l.text.isEmpty) continue;
    final a = l.start, b = l.start + l.dur;
    final w = t < a ? 1 - (a - t) / ramp : (t > b ? 1 - (t - b) / ramp : 1.0);
    if (w > k) k = w;
    if (k >= 1) break;
  }
  return 1 - (1 - d) * k.clamp(0.0, 1.0);
}
