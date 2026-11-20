// Localization, formatting, typography, and user-facing error guards:
//   - Platform font, AppFormat dates/counts, theme accent, LabelFit painting
//     (THEME-02, THEME-04, LAYOUT-04, LAYOUT-06)
//   - ARB duplicate key check & text placeholder allow-list (ERR-05)
//   - Raw error text never reaches user-facing surfaces (ERR-02)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_source_cache.dart';

// ── Format, font, and fitted labels ─────────────────────────────────────────

const _appFormat = 'lib/app/format/app_format.dart';
const _frameworkFormats = 'lib/l10n/app_localizations_delegates.dart';

const _dataDateFormats = <String>{
  'lib/app/navigation/routes.dart',
  'lib/core/download/naming_rule.dart',
  'lib/core/backup/backup_envelope.dart',
};

const _primaryOwners = <String>{
  'lib/app/theme/func_tokens.dart',
  'lib/app/theme/replica_theme.dart',
};

final _dateFormat = RegExp(r'\bDateFormat\b');
final _dateInterpolation = RegExp(r'\$\{[^}]*\.(?:year|month|day)\}');
final _numberFormat = RegExp(r'\bNumberFormat\b');
final _brandPrimary = RegExp(
  r'\bFuncTokens\.(primary|lightAccent|darkAccent|'
  r'(light|dark)(On)?PrimaryContainer|(light|dark)InversePrimary)\b',
);
final _labelMeasure = RegExp(r'\bLabelFit\.(group|measureLabel)\(');
final _identifier = RegExp(r'^[A-Za-z_]\w*$');
final _clause = RegExp(r'^(?:for|if)\s*\(');

// ── ARB duplicate keys & text placeholder allow-list ────────────────────────

const _arbFiles = [
  'lib/l10n/app_zh.arb',
  'lib/l10n/app_en.arb',
  'lib/l10n/app_ja.arb',
  'lib/l10n/app_ru.arb',
];

const _templateArb = 'lib/l10n/app_zh.arb';

const _textPlaceholderKeys = <String, String>{
  'loginNetworkError': 'HTTP status and host',
  'backupExported': 'exported file name',
  'backupImportPrompt': 'account name stored in the backup',
  'imageSourceTestOk': 'HTTP status of a successful probe',
  'imageSourceAutoWinner': 'selected mirror host',
  'networkImageRouteCloudflareColo': 'Cloudflare colo code from the trace',
  'safStorageSdCard': 'storage volume label',
  'namingTemplateHint': 'naming-template variable tokens',
  'downloadGroupAuthorTitle': 'author name',
  'errorWithReason': 'localized action and category',
  'labelValue': 'localized label and the value shown beside it',
  'rankingLoadFailed': 'localized ranking mode label',
  'searchReverseChallenge': 'search engine name',
  'searchReverseEngineUnavailable': 'search engine name',
  'searchReverseBadResponse': 'search engine name',
  'searchReverseTryEngine': 'search engine name',
  'detailMetaCountsSemantics': 'compact counts (AppFormat.count)',
  'detailStatsSemantics': 'compact counts and a formatted date',
  'localNovelsImported': 'novel title',
  'localNovelsDeleteConfirm': 'novel title',
  'localNovelFileEncoding': 'detected charset name',
  'localNovelFileImportedAt': 'formatted date',
  'profileWorksTotal': 'compact count (AppFormat.count)',
  'novelEntryBookmarks': 'compact count (AppFormat.count)',
  'profileTagFilter': 'bookmark tag name',
  'searchRangeAtLeast': 'filter label and formatted bound',
  'searchRangeAtMost': 'filter label and formatted bound',
  'searchRangeBetween': 'filter label and formatted bounds',
  'searchDateFrom': 'formatted date',
  'searchDateUntil': 'formatted date',
  'searchDateBetween': 'formatted dates',
  'rankingDateLabel': 'formatted date',
  'commentTitleCount': 'compact count (AppFormat.count)',
  'historyEmptyRecordingOff': 'localized setting name',
  'networkImageRouteScore': 'one-decimal number (AppFormat.decimal)',
};

const _textTypes = {'String', 'Object'};
final _topLevelKey = RegExp(r'^  "([^"]+)"\s*:', multiLine: true);

// ── Raw error text guard ────────────────────────────────────────────────────

final _textEntry = RegExp(
  r'\bText\('
  r'|\bSelectableText\('
  r'|\bshowAppSnackBar\('
  r'|\bsubtitle\s*:'
  r'|\bdetail\s*:'
  r'|\btitle\s*:'
  r'|\bl10n\.\w+',
);

final _rawError = RegExp(
  r'\$\{?_*\w*(?:error|Error|err|Err|exception|Exception)\b'
  r'|\$\{?_?(?:e|next)\b'
  r'|\b_?\w*(?:error|Error|err|Err|exception|Exception|next)\w*\b(?:\.\w+)*\.toString\(\)'
  r'|\be\.toString\(\)',
);

const _rawErrorAllowList = <String>{
  'lib/features/settings/network_probe_page.dart',
};
const _adjacentLines = 3;

// ── Helpers ─────────────────────────────────────────────────────────────────

List<String> _hits(
  Map<String, String> sources,
  RegExp pattern, {
  Set<String> allowed = const {},
}) => [
  for (final MapEntry(key: file, value: src) in sources.entries)
    if (!allowed.contains(file))
      for (final m in pattern.allMatches(src))
        '  $file:${src.substring(0, m.start).split('\n').length}',
];

String _code(String src) {
  final out = StringBuffer();
  void blank(int from, int to) {
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
      blank(i, to);
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
      blank(i, to);
      i = to;
    } else if (c == "'" || c == '"') {
      final quote = src.startsWith(c * 3, i) ? c * 3 : c;
      final raw = i > 0 && src[i - 1] == 'r';
      var j = i + quote.length;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += !raw && src[j] == r'\' ? 2 : 1;
      }
      final to = j < src.length ? j : src.length;
      out.write(quote);
      blank(i + quote.length, to);
      if (to < src.length) out.write(quote);
      i = to + (to < src.length ? quote.length : 0);
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

List<int> _unpaintedFits(String src) {
  final code = _code(src);
  return [
    for (final m in _labelMeasure.allMatches(code))
      if (!_measuredAsPainted(code, m))
        code.substring(0, m.start).split('\n').length,
  ];
}

List<String> _arguments(String src, int open) {
  final args = <String>[];
  var depth = 0;
  var start = open + 1;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) {
        args.add(src.substring(start, i).trim());
        break;
      }
    } else if (c == ',' && depth == 1) {
      args.add(src.substring(start, i).trim());
      start = i + 1;
    }
  }
  return [
    for (final a in args)
      if (a.isNotEmpty) a,
  ];
}

bool _measuredAsPainted(String src, Match call) {
  final args = _arguments(src, call.end - 1);
  String? named(String name) => [
    for (final a in args)
      if (a.startsWith('$name:')) a.substring(name.length + 1).trim(),
  ].firstOrNull;
  final locale = named('locale');
  final style = call[1] == 'group' ? named('style') : args.elementAtOrNull(1);
  return locale != null &&
      style != null &&
      _traces(src, locale, call.start, 'Localizations.maybeLocaleOf(') &&
      _traces(src, style, call.start, 'LabelFit.paintedStyle(');
}

bool _traces(String src, String expr, int at, String source, [int hops = 3]) {
  if (expr.startsWith(source)) return true;
  if (hops == 0) return false;
  if (expr.startsWith('{') || expr.startsWith('[')) {
    final elements = _arguments(expr, 0);
    return elements.isNotEmpty &&
        elements.every(
          (e) => _traces(src, _withoutClauses(e), at, source, hops - 1),
        );
  }
  if (!_identifier.hasMatch(expr)) return false;
  final binding = RegExp(
    '(?:(?<![\\w.])$expr\\s*=(?!=)|\\bfor\\s*\\(\\s*final\\s+$expr\\s+in\\b)\\s*',
  ).allMatches(src.substring(0, at)).lastOrNull;
  if (binding == null) return false;
  final value = src.substring(binding.end, _expressionEnd(src, binding.end));
  return _traces(src, value.trim(), binding.start, source, hops - 1);
}

String _withoutClauses(String element) {
  var e = element;
  for (
    var clause = _clause.firstMatch(e);
    clause != null;
    clause = _clause.firstMatch(e)
  ) {
    e = e.substring(_expressionEnd(e, clause.end) + 1).trim();
  }
  return e;
}

int _expressionEnd(String src, int from) {
  var depth = 0;
  for (var i = from; i < src.length; i++) {
    final c = src[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      if (depth == 0) return i;
      depth--;
    } else if (';,'.contains(c) && depth == 0) {
      return i;
    }
  }
  return src.length;
}

void main() {
  final libRaw = ArchSourceCache.libRaw();
  final libNoComments = ArchSourceCache.libNoComments();

  test('no bundled Montserrat: text uses the platform font', () {
    final mentions = [
      for (final MapEntry(key: file, value: src) in {
        ...libNoComments,
        'pubspec.yaml': File('pubspec.yaml').readAsStringSync(),
      }.entries)
        if (src.toLowerCase().contains('montserrat')) '  $file',
    ];
    expect(
      mentions,
      isEmpty,
      reason: 'THEME-02 Montserrat is gone — use the platform font:\n$mentions',
    );
  });

  test('user-facing dates go through AppFormat', () {
    final allowed = {_appFormat, _frameworkFormats, ..._dataDateFormats};
    final violations = [
      ..._hits(libNoComments, _dateFormat, allowed: allowed),
      ..._hits(libNoComments, _dateInterpolation, allowed: allowed),
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-06 format dates with AppFormat.date/relative; data '
          'formats go in _dataDateFormats with a reason:\n'
          '${violations.join('\n')}',
    );
  });

  test('counts go through AppFormat', () {
    final violations = _hits(
      libNoComments,
      _numberFormat,
      allowed: {_appFormat, _frameworkFormats},
    );
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-06 format counts with AppFormat.count:\n'
          '${violations.join('\n')}',
    );
  });

  test('the accent comes from the theme, not the brand constant', () {
    final violations = _hits(
      libNoComments,
      _brandPrimary,
      allowed: _primaryOwners,
    );
    expect(
      violations,
      isEmpty,
      reason:
          'THEME-04 read Theme.of(context).colorScheme.primary so system '
          'colors apply:\n${violations.join('\n')}',
    );
  });

  test('the fitted-label scan follows bindings and skips strings', () {
    bool passes(String body) => _unpaintedFits('void f() {\n$body\n}').isEmpty;

    const locale = 'final locale = Localizations.maybeLocaleOf(context);';
    const painted = 'final s = LabelFit.paintedStyle(context, base);';
    expect(
      passes(
        '$locale\n$painted\n'
        "LabelFit.measureLabel('a,(b', s, t, d, locale: locale);",
      ),
      isTrue,
    );
    expect(
      passes(
        '$locale\n$painted\nfinal raw = base;\n'
        "LabelFit.measureLabel('a', raw, t, d, locale: locale);",
      ),
      isFalse,
    );
    expect(
      passes("$painted\nLabelFit.measureLabel('a', s, t, d, locale: null);"),
      isFalse,
    );
    expect(
      passes(
        '$locale\nfinal s = base;\n'
        'holder.s = LabelFit.paintedStyle(context, base);\n'
        "LabelFit.measureLabel('a', s, t, d, locale: locale);",
      ),
      isFalse,
    );
    expect(passes("final note = 'LabelFit.group(';\n"), isTrue);
    expect(passes('/* a /* nested */ LabelFit.group( */\n'), isTrue);
    expect(
      passes(
        "$locale\nfinal url = 'https://example.test';\nfinal raw = base;\n"
        "LabelFit.measureLabel('a', raw, t, d, locale: locale);",
      ),
      isFalse,
    );
  });

  test('fitted labels are measured in the style and locale they paint in', () {
    final violations = [
      for (final MapEntry(key: file, value: src) in libRaw.entries)
        if (file != 'lib/app/widgets/fit_label.dart')
          for (final line in _unpaintedFits(src)) '  $file:$line',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-04 measure with LabelFit.paintedStyle and the painted '
          'locale (Localizations.maybeLocaleOf):\n${violations.join('\n')}',
    );
  });

  test('arb files define every key once', () {
    final duplicates = <String>[];
    for (final path in _arbFiles) {
      final seen = <String>{};
      for (final match in _topLevelKey.allMatches(
        File(path).readAsStringSync(),
      )) {
        final key = match[1]!;
        if (!seen.add(key)) duplicates.add('$path: $key');
      }
    }
    expect(
      duplicates,
      isEmpty,
      reason:
          'ERR-05 duplicate arb keys — the last copy silently wins; keep '
          'one:\n${duplicates.join('\n')}',
    );
  });

  test('text placeholders are allow-listed with a reason', () {
    final arb =
        jsonDecode(File(_templateArb).readAsStringSync())
            as Map<String, dynamic>;
    final textKeys = <String>{};
    for (final entry in arb.entries) {
      if (!entry.key.startsWith('@')) continue;
      final meta = entry.value;
      if (meta is! Map<String, dynamic>) continue;
      final placeholders = meta['placeholders'];
      if (placeholders is! Map<String, dynamic>) continue;
      final hasText = placeholders.values.any(
        (spec) =>
            spec is! Map<String, dynamic> ||
            _textTypes.contains(spec['type'] ?? 'Object'),
      );
      if (hasText) textKeys.add(entry.key.substring(1));
    }

    final unlisted = textKeys.difference(_textPlaceholderKeys.keys.toSet());
    final stale = _textPlaceholderKeys.keys.toSet().difference(textKeys);
    expect(
      unlisted,
      isEmpty,
      reason:
          'ERR-05 keys with a text placeholder must not carry diagnostics — '
          'drop the placeholder (raw text goes into CrashLog) or allow-list '
          'the key with its reason:\n${unlisted.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason:
          'ERR-05 allow-list entries without a text placeholder — remove '
          'them: $stale',
    );
  });

  test('no raw error text reaches user-facing surfaces', () {
    final violations = <String>[];
    for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
      libRaw,
      ['lib/app', 'lib/features'],
    )) {
      if (_rawErrorAllowList.contains(file)) continue;
      final lines = src.split('\n');
      final textLines = <int>[
        for (var i = 0; i < lines.length; i++)
          if (_textEntry.hasMatch(lines[i])) i,
      ];
      final rawLines = <int>[
        for (var i = 0; i < lines.length; i++)
          if (_rawError.hasMatch(lines[i])) i,
      ];
      if (textLines.isEmpty || rawLines.isEmpty) continue;
      for (final t in textLines) {
        final hit = rawLines.where((e) => (e - t).abs() <= _adjacentLines);
        if (hit.isNotEmpty) {
          violations.add(
            '$file:${t + 1} (raw error near line ${hit.first + 1})',
          );
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'ERR-02 raw error values near user-facing text — show a localized '
          'category via errorCategoryText/showErrorSnackBar and keep the '
          'original in CrashLog:\n${violations.join('\n')}',
    );
  });
}
