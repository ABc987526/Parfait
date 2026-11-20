import 'dart:io';

/// Strips `//` line comments and nested `/* ... */` block comments while
/// skipping string literals (`'...'`, `"..."`, triple-quoted, raw `r'...'`),
/// preserving newlines so reported line numbers remain exact.
String _stripComments(String src) {
  final out = StringBuffer();
  void emitSpaces(int from, int to) {
    for (var j = from; j < to; j++) {
      out.write(src[j] == '\n' ? '\n' : ' ');
    }
  }

  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (src.startsWith('//', i)) {
      final end = src.indexOf('\n', i);
      final to = end < 0 ? src.length : end;
      emitSpaces(i, to);
      i = to;
    } else if (src.startsWith('/*', i)) {
      var to = i + 2;
      for (var depth = 1; depth > 0 && to < src.length;) {
        if (src.startsWith('/*', to)) {
          depth++;
          to += 2;
        } else if (src.startsWith('*/', to)) {
          depth--;
          to += 2;
        } else {
          to++;
        }
      }
      emitSpaces(i, to);
      i = to;
    } else if (c == "'" || c == '"') {
      final quote = src.startsWith(c * 3, i) ? c * 3 : c;
      final raw = i > 0 && src[i - 1] == 'r';
      var j = i + quote.length;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += !raw && src[j] == r'\' ? 2 : 1;
      }
      final end = j < src.length ? j + quote.length : src.length;
      out.write(src.substring(i, end));
      i = end;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// Lazily caches repo source files once per test isolate so merged
/// architecture checks do not re-walk and re-read `lib/` and `test/`.
class ArchSourceCache {
  ArchSourceCache._();

  static Map<String, String>? _libRaw;
  static Map<String, String>? _libNoComments;
  static Map<String, String>? _testRaw;
  static Map<String, String>? _specRaw;

  static Map<String, String> _readTree(
    String dir, {
    required bool Function(String path) accept,
  }) {
    final result = <String, String>{};
    for (final entity in Directory(dir).listSync(recursive: true)) {
      if (entity is File && accept(entity.path)) {
        result[entity.path] = entity.readAsStringSync();
      }
    }
    return result;
  }

  /// All `lib/**/*.dart` files mapped to their raw source text.
  static Map<String, String> libRaw() =>
      _libRaw ??= _readTree('lib', accept: (p) => p.endsWith('.dart'));

  /// All `lib/**/*.dart` files mapped to comment-stripped source text.
  static Map<String, String> libNoComments() => _libNoComments ??= {
    for (final MapEntry(key: path, value: src) in libRaw().entries)
      path: _stripComments(src),
  };

  /// All `test/**/*.dart` files (excluding `test/fixtures/`) mapped to raw text.
  static Map<String, String> testRaw() => _testRaw ??= _readTree(
    'test',
    accept: (p) => p.endsWith('.dart') && !p.startsWith('test/fixtures/'),
  );

  /// All `.trellis/spec/**/*.md` files mapped to raw text.
  static Map<String, String> specRaw() =>
      _specRaw ??= _readTree('.trellis/spec', accept: (p) => p.endsWith('.md'));

  /// Sub-map of [sources] whose paths start with any prefix in [prefixes].
  static Iterable<MapEntry<String, String>> under(
    Map<String, String> sources,
    List<String> prefixes,
  ) => sources.entries.where(
    (entry) => prefixes.any(
      (prefix) =>
          entry.key == prefix ||
          entry.key.startsWith(prefix.endsWith('/') ? prefix : '$prefix/'),
    ),
  );
}
