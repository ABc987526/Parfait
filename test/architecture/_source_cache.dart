import 'dart:io';

final _commentPattern = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);

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
      path: src.replaceAll(_commentPattern, ''),
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
