// The XML subset TSVG needs: elements, attributes, text, comments, <?…?>,
// <!…>, CDATA, the 5 named entities and numeric ones. A direct port of the
// reference parser so error messages and edge cases match.
import 'js.dart';

class XmlEl {
  XmlEl(this.name, {this.line = 0});
  final String name;
  final Map<String, String> attrs = <String, String>{};
  final List<XmlEl> children = <XmlEl>[];
  String text = '';
  final int line;
}

const Map<String, String> _ent = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"};
final RegExp _entRe = RegExp(r'&(#x[0-9a-f]+|#[0-9]+|[a-z]+);', caseSensitive: false);

String unent(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entRe, (m) {
    final e = m[1]!;
    if (e[0] == '#') {
      final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
      final code = hex ? int.parse(e.substring(2), radix: 16) : int.parse(e.substring(1));
      return String.fromCharCode(code);
    }
    return _ent[e] ?? m[0]!;
  });
}

final RegExp _closeRe = RegExp(r'</([A-Za-z_][\w:.-]*)\s*>');
final RegExp _openRe = RegExp(r'<([A-Za-z_][\w:.-]*)');
final RegExp _wsRe = RegExp(r'\s*');
final RegExp _attrRe = RegExp(r'''([A-Za-z_][\w:.-]*)\s*=\s*("([^"]*)"|'([^']*)')''');

int _lineAt(String src, int i) {
  var n = 1;
  for (var k = 0; k < i && k < src.length; k++) {
    if (src.codeUnitAt(k) == 10) n++;
  }
  return n;
}

/// Parses [src] and returns the single root element.
XmlEl parseXml(String src) {
  var i = 0;
  Never fail(String msg) => throw TsvgError('XML line ${_lineAt(src, i)}: $msg');
  final rootEl = XmlEl('#root');
  final stack = <XmlEl>[rootEl];
  while (i < src.length) {
    final lt = src.indexOf('<', i);
    final textEnd = lt < 0 ? src.length : lt;
    if (textEnd > i) {
      stack.last.text += unent(src.substring(i, textEnd));
      i = textEnd;
      continue;
    }
    if (src.startsWith('<!--', i)) {
      final e = src.indexOf('-->', i);
      if (e < 0) fail('unclosed comment');
      i = e + 3;
      continue;
    }
    if (src.startsWith('<![CDATA[', i)) {
      final e = src.indexOf(']]>', i);
      if (e < 0) fail('unclosed CDATA');
      stack.last.text += src.substring(i + 9, e);
      i = e + 3;
      continue;
    }
    if (src.startsWith('<?', i) || src.startsWith('<!', i)) {
      final e = src.indexOf('>', i);
      if (e < 0) fail('unclosed declaration');
      i = e + 1;
      continue;
    }
    if (src.startsWith('</', i)) {
      final m = _closeRe.matchAsPrefix(src, i);
      if (m == null) fail('bad closing tag');
      final top = stack.length > 1 ? stack.removeLast() : null;
      if (top == null || top.name != m[1]) fail('expected </${top?.name}> but found </${m[1]}>');
      i = m.end;
      continue;
    }
    final m = _openRe.matchAsPrefix(src, i);
    if (m == null) fail('bad tag');
    final el = XmlEl(m[1]!, line: _lineAt(src, i));
    i = m.end;
    for (;;) {
      i = _wsRe.matchAsPrefix(src, i)!.end;
      if (src.startsWith('/>', i)) {
        i += 2;
        stack.last.children.add(el);
        break;
      }
      if (i < src.length && src[i] == '>') {
        i++;
        stack.last.children.add(el);
        stack.add(el);
        break;
      }
      final a = _attrRe.matchAsPrefix(src, i);
      if (a == null) fail('bad attribute in <${el.name}>');
      if (el.attrs.containsKey(a[1])) fail('duplicate attribute ${a[1]} in <${el.name}>');
      el.attrs[a[1]!] = unent(a[3] ?? a[4]!);
      i = a.end;
    }
  }
  if (stack.length > 1) fail('unclosed <${stack.last.name}>');
  final els = rootEl.children;
  if (els.length != 1) fail('expected exactly one root element');
  return els.first;
}
