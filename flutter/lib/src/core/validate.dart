// Static checks + a dry run of every frame sample under every option set and
// layout against a recording backend (port of `validate`).
import 'dart:convert';

import 'audio.dart';
import 'canvas.dart';
import 'js.dart';
import 'model.dart';
import 'render.dart';

class ValidationResult {
  ValidationResult(this.ok, this.errors, this.warnings, this.doc, [this.stats]);
  final bool ok;
  final List<String> errors, warnings;
  final TsvgDoc? doc;
  final Map<String, num>? stats;
}

final RegExp _remote = RegExp(r'^(https?|data):');

ValidationResult validate(String xml, {bool Function(String path)? has, int samples = 4}) {
  final errors = <String>[], warnings = <String>[];
  final TsvgDoc doc;
  try {
    doc = parseTsvg(xml);
  } on TsvgError catch (e) {
    return ValidationResult(false, [e.message], warnings, null);
  }
  final langOpt = doc.options.where((o) => o.id == 'lang');
  final langs = langOpt.isEmpty ? <String>[] : [for (final c in langOpt.first.choices) c.id];
  doc.strings.forEach((id, s) {
    for (final l in langs) {
      if (s[l] == null) warnings.add('string @$id has no "$l" text (falls back)');
    }
  });
  for (final o in doc.options) {
    if ((o.defaultValue ?? '').isNotEmpty && !o.choices.any((c) => c.id == o.defaultValue)) {
      errors.add('option ${o.id}: default "${o.defaultValue}" is not a choice');
    }
  }
  for (final o in doc.options.where((o) => o.id == 'mix')) {
    for (final c in o.choices) {
      if (!doc.mixes.containsKey(c.id)) errors.add('mix choice "${c.id}" has no <mix id="${c.id}">');
    }
  }
  for (final o in doc.options.where((o) => o.id == 'theme')) {
    for (final c in o.choices) {
      if (!doc.themes.containsKey(c.id)) errors.add('theme choice "${c.id}" has no <theme id="${c.id}">');
    }
  }
  void ref(String? r, String what) {
    final p = assetPath(doc, r);
    if (p == null || p.isEmpty) {
      errors.add('$what: missing src');
    } else if (has != null && !has(p) && !_remote.hasMatch(p)) {
      errors.add('$what: file not in package: $p');
    }
  }

  doc.assets.forEach((id, a) => ref(a.src, 'asset $id'));
  for (final f in doc.fonts) {
    ref(f.src, 'font ${f.family}');
  }
  for (final a in doc.audio) {
    if (!doc.assets.containsKey(a.src) && !(a.src ?? '').contains('/')) {
      errors.add('audio src "${a.src}" is neither an asset id nor a path');
    }
  }
  for (final v in doc.voices.values) {
    ref(v.src, 'voice');
  }
  final ls = langs.isNotEmpty ? langs : ['en'];
  for (final s in doc.says) {
    for (final l in ls) {
      final c = s.raw['src.$l'];
      if (c != null && c.isNotEmpty && !doc.assets.containsKey(c) && !c.contains('/')) {
        errors.add('say ${s.key}: src.$l "$c" unknown');
      }
    }
  }
  for (final l in ls) {
    final dl = forOptions(doc, {...defaultOptions(doc), 'lang': l}).duration;
    final lines = sayLines(doc, {...defaultOptions(doc), 'lang': l})..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 0; i < lines.length; i++) {
      final ln = lines[i];
      if (ln.clip == null) warnings.add('say ${ln.key} [$l]: no recorded clip (engine TTS or captions only) — run `tsvg bake`');
      final next = i + 1 < lines.length ? lines[i + 1] : null;
      final end = ln.start + ln.dur;
      if (next != null && end > next.start + 0.05) {
        warnings.add('say ${ln.key} [$l] ends at ${jsFixed(end, 2)}s, overlaps ${next.key} at ${jsFixed(next.start, 2)}s');
      }
      if (end > dl + 0.05) {
        warnings.add('say ${ln.key} [$l] runs past the end (${jsFixed(end, 2)}s > ${jsFixed(dl, 2)}s)');
      }
    }
  }
  final ctx = RecordingCanvas();
  final sets = optionCombos(doc);
  final seen = <String>{};
  outer:
  for (final layout in doc.layouts) {
    for (final opts in sets.isNotEmpty ? sets : [<String, String>{}]) {
      final v = forOptions(doc, {...defaultOptions(doc), ...opts});
      final n = samples * v.scenes.length;
      for (var i = 0; i <= n; i++) {
        final t = n == 0 ? 0.0 : v.duration * i / n;
        try {
          renderFrame(ctx, doc, t, {...defaultOptions(doc), ...opts}, layout);
        } catch (e) {
          final k = e is TsvgError ? e.message : e.toString();
          if (seen.add(k)) errors.add('render ${layout.id} ${jsonEncode(opts)} t=${jsFixed(t, 2)}: $k');
          if (errors.length > 30) break outer;
        }
      }
    }
  }
  return ValidationResult(errors.isEmpty, errors, warnings, doc, {
    'duration': doc.duration,
    'scenes': doc.scenes.length,
    'layouts': doc.layouts.length,
    'variants': sets.length * doc.layouts.length,
    'says': doc.says.length,
  });
}
