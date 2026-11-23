/// Pure-Dart TSVG core (no Flutter): parser, expressions, value resolution,
/// frame walker over an abstract canvas, audio plan, packages, validator.
library;

export 'src/core/audio.dart';
export 'src/core/canvas.dart';
export 'src/core/color.dart' show Rgba, cssColor, parseColor, lerpAny, withAlpha;
export 'src/core/expr.dart' show Env, Expr, UserFn, compileExpr, compiled, lookup, ease, builtins;
export 'src/core/js.dart' show TsvgError, toNum, toStr, truthy;
export 'src/core/model.dart';
export 'src/core/path_data.dart';
export 'src/core/render.dart';
export 'src/core/source.dart';
export 'src/core/validate.dart';
export 'src/core/xml.dart' show XmlEl, parseXml;
