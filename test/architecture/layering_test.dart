// Layering rules for lib/ (see .trellis/spec/guides/architecture.md).
//
// Rules asserted on the import graph:
//   R1  lib/core/** must not import lib/features/** or lib/app/**
//   R2  lib/features/<a>/** must not import lib/features/<b>/** (a != b)
//   R3  lib/app/** must not import lib/features/** except the router/workspace
//       assembly facades (routes.dart, me_workspace_facade.dart)
//   R4  lib/features/** must not own data-layer files
//       (*repository.dart, *_controller.dart, *_models.dart entity files)
//   R5  lib/features/** must not define shared-component widgets
//       (class _*Tail / _*Error / _*Empty / _*Card / _*Status / _*Placeholder)
//   R6  lib/app/navigation/routes.dart may only be imported by
//       lib/app/app.dart and lib/app/external_intent_bridge.dart
//   R7  lib/app/navigation/routes.dart must not export lib/features/**
//   R8  lib/app/window/desktop_command_bar.dart may only be imported by
//       lib/app/app.dart
//
// The allow-lists below are empty and must stay empty: fix a violation instead
// of allow-listing it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

final _finalRegExp = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _exportRegExp = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _partRegExp = RegExp(r'''^\s*part\s+['"]([^'"]+)['"]''', multiLine: true);

/// (from-file, to-file) edges that are known violations, allow-listed until
/// the owning refactor lands. Format: "lib/... -> lib/...".
const _allowListedEdges = <String>{};

/// R4: data-layer files still under lib/features/ (C4 moves them to lib/core/).
const _allowListedDataFiles = <String>{};

/// R5: files defining shared-component private widgets (C3/C8 replaces them).
const _allowListedWidgetFiles = <String>{};

// ---------------------------------------------------------------------------

/// Returns repo-relative paths of all lib/*.dart files.
List<String> _dartFiles(String root) {
  final files = <String>[];
  void walk(Directory dir) {
    for (final e in dir.listSync()) {
      if (e is Directory) {
        walk(e);
      } else if (e is File && e.path.endsWith('.dart')) {
        files.add(e.path.substring(root.length + 1));
      }
    }
  }

  walk(Directory('$root/lib'));
  return files;
}

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

String _featureOf(String path) {
  final parts = path.split('/');
  if (parts.length >= 3 && parts[0] == 'lib' && parts[1] == 'features') {
    return parts[2];
  }
  return '';
}

void main() {
  test(
    'lib import graph respects layering rules (allow-list must shrink to empty)',
    () {
      final files = _dartFiles(Directory.current.path);
      final edges = <String>{}; // "from -> to"
      final exportEdges = <String>{}; // "from -> to" (export only)
      final dataLayerFiles = <String>{};
      final widgetFiles = <String>{};

      final sharedWidgetPattern = RegExp(
        r'^\s*class\s+_(?:\w*)(?:Tail|Error|Empty|Card|Status|Placeholder)\b',
        multiLine: true,
      );

      for (final f in files) {
        final src = File(f).readAsStringSync();
        for (final m in _finalRegExp.allMatches(src)) {
          final uri = m.group(1)!;
          final to = _resolveUri(f, uri);
          if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
        }
        for (final m in _exportRegExp.allMatches(src)) {
          final uri = m.group(1)!;
          final to = _resolveUri(f, uri);
          if (to != null && to.startsWith('lib/')) {
            exportEdges.add('$f -> $to');
          }
        }
        for (final m in _partRegExp.allMatches(src)) {
          final uri = m.group(1)!;
          final to = _resolveUri(f, uri);
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
          final fa = _featureOf(from);
          final fb = _featureOf(to);
          if (fa != fb) {
            violations.add(e);
          }
        } else if (fromLayer == 'app' && toLayer == 'features') {
          if (!_appFeatureFacades.contains(from)) violations.add(e);
        }

        // R6: routes.dart is the full router assembly; callers must import
        // route_facade.dart / route_search_facade.dart / route_extras.dart /
        // route_query_codecs.dart instead.
        if (to == 'lib/app/navigation/routes.dart' &&
            !_routesAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R6 $e');
        }
        // Narrow scope for me_workspace_facade.dart so it cannot grow into a
        // second mega-barrel.
        if (to == 'lib/app/navigation/me_workspace_facade.dart' &&
            !_meWorkspaceAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R3-scope $e');
        }
        // R8: desktop_command_bar.dart is app chrome assembly; pages and
        // widgets must import desktop_command_bar_scope.dart instead.
        if (to == 'lib/app/window/desktop_command_bar.dart' &&
            !_commandBarAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R8 $e');
        }
      }

      // R7: routes.dart must never re-export features/** widgets.
      for (final e in exportEdges) {
        final parts = e.split(' -> ');
        final from = parts[0];
        final to = parts[1];
        if (from == 'lib/app/navigation/routes.dart' &&
            _layerOf(to) == 'features') {
          compileCouplingViolations.add('R7 $e');
        }
      }

      final unlisted = violations.difference(_allowListedEdges);
      final stale = _allowListedEdges.difference(violations);
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
      // Print remaining allow-list so the next refactor knows what to remove.
      if (stale.isNotEmpty) {
        // ignore: avoid_print
        print(
          'Allow-list entries that no longer violate (remove them):\n${stale.join('\n')}',
        );
      }
      // ignore: avoid_print
      print(
        'Still allow-listed: ${_allowListedEdges.length} edges, '
        '${_allowListedDataFiles.length} data files, ${_allowListedWidgetFiles.length} widget files.',
      );
    },
  );
}

String _layerOf(String path) {
  if (!path.startsWith('lib/')) return 'other';
  final parts = path.split('/');
  if (parts[1] == 'core' || parts[1] == 'features' || parts[1] == 'app') {
    return parts[1];
  }
  return 'lib-root';
}
