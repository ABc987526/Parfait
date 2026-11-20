// Layering & test-hygiene static scans:
//   - lib/ import graph & compile-graph decoupling rules R1–R8 (ARCH-01, ARCH-02)
//   - test/ hygiene guards (TEST-04, TEST-05, TEST-07, TEST-09, TEST-10, TEST-11):
//     * file size <= 1500 lines
//     * unique test doubles (by name & body), no app repository doubles
//     * no skipped cases, socket tests tagged, preferences via helpers
//     * no real sleeps, no fixed-round non-zero Future.delayed polling loops
//     * no roadmap-phase test filenames
//     * no raw isolate-backed databaseFactoryFfi in widget tests

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_source_cache.dart';

// ── Layering rules (ARCH-01 / ARCH-02) ──────────────────────────────────────

const _package = 'parfait';

const _appFeatureFacades = <String>{
  'lib/app/navigation/routes.dart',
  'lib/app/navigation/me_workspace_facade.dart',
};

const _routesAllowedImporters = <String>{
  'lib/app/app.dart',
  'lib/app/external_intent_bridge.dart',
};

const _meWorkspaceAllowedImporters = <String>{
  'lib/features/settings/me_dashboard_page.dart',
};

const _commandBarAllowedImporters = <String>{'lib/app/app.dart'};

final _importOrExportRegExp = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _exportRegExp = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _partRegExp = RegExp(r'''^\s*part\s+['"]([^'"]+)['"]''', multiLine: true);

const _allowListedEdges = <String>{};
const _allowListedDataFiles = <String>{};
const _allowListedWidgetFiles = <String>{};

// ── Test hygiene rules ──────────────────────────────────────────────────────

const _maxFileLines = 1500;
const _self = 'test/architecture/layering_and_hygiene_test.dart';

final _doubleClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class _?('
  r'(?:Fake|Stub|Recording|Scripted|Failing|Spy|Counting|Mock|Throwing|'
  r'Unused|Switchable|Memory|InMemory|Static|Blocking|Controlled|Manual|'
  r'Capturing)[A-Z]\w*)',
  multiLine: true,
);

final _repositoryDouble = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class (\w+)[^{;]*'
  r'\b(?:extends|implements|with)\b[^{;]*?\b(\w*Repository)\b',
  multiLine: true,
);

final _topClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class (\w+)[^{;]*\{',
  multiLine: true,
);
final _widgetClass = RegExp(
  r'extends (?:State<|StatelessWidget|StatefulWidget|ConsumerWidget|'
  r'ConsumerStatefulWidget|ConsumerState<)',
);

const _sameBody = 0.8;
const _minBodyLines = 10;
final _skip = RegExp(r'(?<![\w.])skip:|@Skip\(');
final _sleep = RegExp(r'(?<![\w.])sleep\(');

final _ownPreferences = RegExp(
  r'SharedPreferencesAsyncPlatform\.instance\s*=(?!=)|'
  r'\binstallMemoryPreferences(?:\(\s*\)|(?!\())',
);
const _preferencesHelper = 'test/helpers/test_preferences.dart';
final _socket = RegExp(
  r'\b(?:HttpServer|(?:Raw)?(?:Secure)?ServerSocket|RawDatagramSocket)'
  r'\.bind|\b(?:Raw)?(?:Secure)?Socket\.(?:connect|startConnect)\(',
);
final _socketTag = RegExp(r"^@Tags\(\[[^\]]*'socket'", multiLine: true);

/// Roadmap/audit phase filenames that bundle unrelated features and drift out
/// of module ownership.
final _phaseTestName = RegExp(
  r'(?:^|/)(?:.*(?:phase\d+|matrix_gate|p0_p1)|.*_audit)_test\.dart$',
  caseSensitive: false,
);

/// A `for`/`while` loop body containing a non-zero `Future.delayed(Duration(...))`.
/// Zero-delay yields (`Duration.zero`) drain microtasks and are fine.
final _fixedDelayLoop = RegExp(
  r'\b(?:for|while)\s*\([^)]*\)\s*\{[^{}]{0,400}'
  r'Future(?:<[^>]+>)?\.delayed\(\s*(?:const\s+)?Duration\(',
  dotAll: true,
);

/// Files permitted to loop over non-zero `Future.delayed`: the shared
/// condition-driven `pumpIoUntil` waiter, the review harness's image-decode
/// / streaming chunk pacing, and the real-socket image worker isolate test
/// releasing held loopback responses.
const _delayedLoopAllowList = <String>{
  'test/helpers/waits.dart',
  'test/image_worker_host_test.dart',
  'test/review/review_support.dart',
  'test/review/review_world.dart',
};

/// Raw isolate-backed `databaseFactoryFfi` (not `databaseFactoryFfiNoIsolate`).
final _rawFfiDb = RegExp(r'\bdatabaseFactoryFfi\b');

/// Widget-containing test files explicitly verifying on-disk SQLite
/// persistence/backup behavior across isolates.
const _widgetFfiDbAllowList = <String>{
  'test/backup_test.dart',
  'test/watch_later_store_test.dart',
};

// ── Helpers ─────────────────────────────────────────────────────────────────

String? _resolveUri(String fromFile, String uri) {
  if (uri.startsWith('package:$_package/')) {
    final cand = 'lib/${uri.substring(_package.length + 8)}';
    return File(cand).existsSync() ? cand : null;
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  final base = fromFile.substring(0, fromFile.lastIndexOf('/'));
  final resolved = Uri.parse('$base/$uri').normalizePath().toString();
  return File(resolved).existsSync() ? resolved : null;
}

String _layerOf(String path) {
  if (!path.startsWith('lib/')) return 'other';
  final parts = path.split('/');
  if (parts[1] == 'core' || parts[1] == 'features' || parts[1] == 'app') {
    return parts[1];
  }
  return 'lib-root';
}

String _featureOf(String path) {
  final parts = path.split('/');
  if (parts.length >= 3 && parts[0] == 'lib' && parts[1] == 'features') {
    return parts[2];
  }
  return '';
}

Iterable<({String path, String name, List<String> lines})> _classBodies(
  Map<String, String> sources,
) sync* {
  for (final MapEntry(key: path, value: source) in sources.entries) {
    for (final match in _topClass.allMatches(source)) {
      if (_widgetClass.hasMatch(match[0]!)) continue;
      final name = match[1]!;
      final end = source.indexOf('\n}', match.start);
      if (end < 0) continue;
      final lines = [
        for (final line in source.substring(match.start, end).split('\n'))
          if (line.trim().replaceAll(name, 'X') case final text
              when text.length > 3 && !text.startsWith('//'))
            text,
      ];
      if (lines.length >= _minBodyLines) {
        yield (path: path, name: name, lines: lines);
      }
    }
  }
}

double _overlap(List<String> a, List<String> b) {
  final counts = <String, int>{};
  for (final line in a) {
    counts[line] = (counts[line] ?? 0) + 1;
  }
  var common = 0;
  for (final line in b) {
    if ((counts[line] ?? 0) > 0) {
      counts[line] = counts[line]! - 1;
      common++;
    }
  }
  return common / (a.length < b.length ? a.length : b.length);
}

void main() {
  final libSources = ArchSourceCache.libRaw();
  final testSources = {
    for (final MapEntry(key: path, value: src)
        in ArchSourceCache.testRaw().entries)
      if (path != _self) path: src,
  };

  test(
    'lib import graph respects layering rules (allow-list must shrink to empty)',
    () {
      final edges = <String>{};
      final exportEdges = <String>{};
      final dataLayerFiles = <String>{};
      final widgetFiles = <String>{};

      final sharedWidgetPattern = RegExp(
        r'^\s*class\s+_(?:\w*)(?:Tail|Error|Empty|Card|Status|Placeholder)\b',
        multiLine: true,
      );

      for (final MapEntry(key: f, value: src) in libSources.entries) {
        for (final m in _importOrExportRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
        }
        for (final m in _exportRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) {
            exportEdges.add('$f -> $to');
          }
        }
        for (final m in _partRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
        }
        if (f.startsWith('lib/features/')) {
          if (RegExp(
            r'(?:repository|_controller|_models)\.dart$',
          ).hasMatch(f)) {
            dataLayerFiles.add(f);
          }
          if (sharedWidgetPattern.hasMatch(src)) {
            widgetFiles.add(f);
          }
        }
      }

      final violations = <String>{};
      final compileCouplingViolations = <String>{};
      for (final e in edges) {
        final parts = e.split(' -> ');
        final from = parts[0];
        final to = parts[1];
        final fromLayer = _layerOf(from);
        final toLayer = _layerOf(to);
        if (fromLayer == 'core' &&
            (toLayer == 'features' || toLayer == 'app')) {
          violations.add(e);
        } else if (fromLayer == 'features' && toLayer == 'features') {
          if (_featureOf(from) != _featureOf(to)) violations.add(e);
        } else if (fromLayer == 'app' && toLayer == 'features') {
          if (!_appFeatureFacades.contains(from)) violations.add(e);
        }

        if (to == 'lib/app/navigation/routes.dart' &&
            !_routesAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R6 $e');
        }
        if (to == 'lib/app/navigation/me_workspace_facade.dart' &&
            !_meWorkspaceAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R3-scope $e');
        }
        if (to == 'lib/app/window/desktop_command_bar.dart' &&
            !_commandBarAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R8 $e');
        }
      }

      for (final e in exportEdges) {
        final parts = e.split(' -> ');
        if (parts[0] == 'lib/app/navigation/routes.dart' &&
            _layerOf(parts[1]) == 'features') {
          compileCouplingViolations.add('R7 $e');
        }
      }

      final unlisted = violations.difference(_allowListedEdges);
      final unlistedData = dataLayerFiles.difference(_allowListedDataFiles);
      final unlistedWidgets = widgetFiles.difference(_allowListedWidgetFiles);

      expect(
        unlisted,
        isEmpty,
        reason:
            'ARCH-01 layering violations — navigate through '
            'lib/app/navigation/route_facade.dart, keep core free of '
            'app/features:\n${unlisted.join('\n')}',
      );
      expect(
        compileCouplingViolations,
        isEmpty,
        reason:
            'ARCH-01 compile-graph decoupling violations (R6/R7/R8) — import '
            'narrow facade/scope libraries instead of routes.dart or '
            'desktop_command_bar.dart:\n'
            '${compileCouplingViolations.join('\n')}',
      );
      expect(
        unlistedData,
        isEmpty,
        reason:
            'ARCH-02 data-layer files under features/ — move them to '
            'lib/core/<domain>/:\n${unlistedData.join('\n')}',
      );
      expect(
        unlistedWidgets,
        isEmpty,
        reason:
            'ARCH-02 shared-component widgets in features/ — use or extend '
            'the lib/app/widgets/ component:\n${unlistedWidgets.join('\n')}',
      );
    },
  );

  test('test files stay under $_maxFileLines lines', () {
    final long = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if ('\n'.allMatches(source).length case final lines
            when lines > _maxFileLines)
          '$path ($lines lines)',
    ];
    expect(
      long,
      isEmpty,
      reason:
          'TEST-05 split these by feature, with shared fakes in '
          'test/helpers/',
    );
  });

  test('each test double is defined once', () {
    final definitions = <String, List<String>>{};
    for (final MapEntry(key: path, value: source) in testSources.entries) {
      for (final match in _doubleClass.allMatches(source)) {
        (definitions[match.group(1)!] ??= []).add(path);
      }
    }
    expect(
      {
        for (final MapEntry(key: name, value: paths) in definitions.entries)
          if (paths.length > 1) name: paths,
      },
      isEmpty,
      reason:
          'TEST-10 keep one copy in test/helpers/ and import it, or name a '
          'double that behaves differently after how it differs',
    );
  });

  test('no test double is copied into a second file', () {
    final bodies = _classBodies(testSources).toList();
    final copies = [
      for (final (i, a) in bodies.indexed)
        for (final b in bodies.skip(i + 1))
          if (a.path != b.path && _overlap(a.lines, b.lines) >= _sameBody)
            '${a.path} ${a.name} ~ ${b.path} ${b.name}',
    ];
    expect(
      copies,
      isEmpty,
      reason:
          'TEST-10 share one double from test/helpers/ (a parameter covers '
          'a small difference) instead of a near-copy',
    );
  });

  test('no test double stands in for an app repository', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          for (final match in _repositoryDouble.allMatches(source))
            '$path ${match[1]} (${match[2]})',
      ],
      isEmpty,
      reason:
          'TEST-10 run the app\'s repository over a fake boundary: PixivApi '
          'routes for the App API, in-memory preferences or databases for '
          'stored data',
    );
  });

  test('no skipped cases', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (_skip.hasMatch(source)) path,
      ],
      isEmpty,
      reason: 'TEST-04 fix or delete the case instead of skipping it',
    );
  });

  test('socket tests carry the socket tag', () {
    final untagged = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if (_socket.hasMatch(source) &&
            !(path.endsWith('_test.dart') && _socketTag.hasMatch(source)))
          path,
    ];
    expect(
      untagged,
      isEmpty,
      reason:
          'TEST-07 open real sockets in the test file and tag it '
          "@Tags(['socket']) above `library;`",
    );
  });

  test('no file sets empty preferences of its own', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (path != _preferencesHelper &&
              !path.endsWith('/flutter_test_config.dart') &&
              _ownPreferences.hasMatch(source))
            path,
      ],
      isEmpty,
      reason:
          'TEST-09 install values with installMemoryPreferences(data), a '
          'failing or gated platform with installPreferencesForTest',
    );
  });

  test('no real sleeps', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (_sleep.hasMatch(source)) path,
      ],
      isEmpty,
      reason:
          'TEST-11 sleep blocks the isolate; advance fake time with '
          'fakeAsync or tester.pump(duration)',
    );
  });

  test('no roadmap-phase test filenames', () {
    final bad = [
      for (final path in testSources.keys)
        if (_phaseTestName.hasMatch(path)) path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-05 name test files after the module or feature they verify, '
          'not roadmap phases or audit passes',
    );
  });

  test('no fixed-round Future.delayed polling loops', () {
    final bad = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if (!_delayedLoopAllowList.contains(path) &&
            _fixedDelayLoop.hasMatch(source))
          path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-11 wait on a condition with pumpIoUntil or yield with '
          'Duration.zero instead of looping fixed Future.delayed durations',
    );
  });

  test('no raw databaseFactoryFfi in widget tests', () {
    final bad = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if (path != 'test/flutter_test_config.dart' &&
            !_widgetFfiDbAllowList.contains(path) &&
            source.contains('testWidgets(') &&
            _rawFfiDb.hasMatch(source))
          path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-07 widget tests must use default in-memory no-isolate SQLite '
          '(databaseFactoryFfiNoIsolate); keep on-disk isolate FFI databases '
          'in dedicated persistence unit tests',
    );
  });
}
