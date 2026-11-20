import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, kSecondaryMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'review_support.dart';

/// Drives applicable catalog items under simulated Apple viewports (`iphone`,
/// `ipad`, `ipad-landscape`, `macos`) and exports 30fps PNG frames for external
/// `widget_tester_simulation` encoding.
void main() {
  final deviceName = reviewDeviceName;
  final applePlatformKey = switch (deviceName) {
    'iphone' => 'iphone',
    'ipad' || 'ipad-landscape' => 'ipad',
    'macos' => 'macos',
    _ => null,
  };
  if (applePlatformKey == null) return;

  final rawCatalog = File(
    'tool/dev_workbench/catalog/catalog.json',
  ).readAsStringSync();
  final decoded = jsonDecode(rawCatalog) as Map<String, dynamic>;
  final allItems = (decoded['items'] as List).cast<Map<String, dynamic>>();

  final idFilterRaw = (Platform.environment['PARFAIT_CATALOG_ID'] ?? '').trim();
  final idFilter = idFilterRaw.isEmpty
      ? <String>{}
      : {
          for (final s in idFilterRaw.split(','))
            if (s.trim().isNotEmpty) s.trim(),
        };

  for (final item in allItems) {
    final cid = item['id'] as String;
    if (idFilter.isNotEmpty && !idFilter.contains(cid)) continue;
    final platforms = (item['platforms'] as Map).cast<String, dynamic>();
    final rule = (platforms[applePlatformKey] ?? '').toString();
    if (rule != 'required') continue;

    final simRoute = (item['sim_route'] ?? item['route']).toString();
    final simSetupMap =
        (item['sim_setup'] as Map?)?.cast<String, dynamic>() ?? const {};
    final states = (item['states'] as List).cast<String>();
    final useWideIpad =
        applePlatformKey == 'ipad' && states.contains('wide_two_pane');

    testWidgets('sim/$deviceName/$cid', (tester) async {
      await reviewScene(tester, () async {
        final setup = _buildReviewSetup(simSetupMap);
        final activeDevice = useWideIpad
            ? reviewDevices['ipad-landscape']
            : null;
        final world = await tester.runAsync(() async {
          final w = await ReviewWorld.open(setup);
          if (!setup.signedIn &&
              (simRoute.startsWith('/login') ||
                  simRoute == '/user-agreement')) {
            await w.container.read(settingsProvider.notifier).completeGuide();
          }
          return w;
        });
        final router = await pumpReviewApp(
          tester,
          world: world!,
          location: simRoute,
          device: activeDevice,
          platform: (activeDevice ?? reviewDevice).targetPlatform,
        );
        await settleReview(tester, limit: const Duration(seconds: 6));

        final film = FilmRecorder(tester, cid, simRoute);
        final isPointer =
            (activeDevice ?? reviewDevice).targetPlatform ==
            TargetPlatform.macOS;
        String? anomaly;
        await film.frames(2);
        try {
          await _runCatalogActions(
            film,
            router,
            world,
            item,
            isPointer: isPointer,
          );
        } on Object catch (error) {
          anomaly = error.toString();
        }
        await film.frames(2);

        final notes = StringBuffer()
          ..writeln('evidence_kind: widget_tester_simulation')
          ..writeln('device: ${useWideIpad ? "ipad-landscape" : deviceName}')
          ..writeln('route: $simRoute');
        if (anomaly != null) {
          notes.writeln('ANOMALY: $anomaly');
        }
        await film.write(notes.toString());

        final resultFile = File('${ReviewRun.dir}/films/$cid/sim_result.json')
          ..parent.createSync(recursive: true);
        resultFile.writeAsStringSync(
          jsonEncode({
            'catalog_id': cid,
            'platform': applePlatformKey,
            'device': useWideIpad ? 'ipad-landscape' : deviceName,
            'evidence_kind': 'widget_tester_simulation',
            'capture_mode': 'flutter_test_film_recorder',
            'route_before': simRoute,
            'route_after': router.routerDelegate.currentConfiguration.uri
                .toString(),
            'frames': film.length,
            'anomaly': anomaly,
          }),
        );
      });
    }, tags: reviewTags);
  }
}

ReviewSetup _buildReviewSetup(Map<String, dynamic> simSetup) {
  final api = <String, ReviewResponder>{};
  if (simSetup['emptyRecommended'] == true) {
    api['/v1/illust/recommended'] = reviewEmpty('illusts');
  }
  if (simSetup['errorRecommended'] == true) {
    api['/v1/illust/recommended'] = reviewError(500);
  }
  return ReviewSetup(
    api: api,
    signedIn: simSetup['signedIn'] as bool? ?? true,
    history: simSetup['withHistory'] == true ? reviewHistory() : const [],
    watchlater: (simSetup['watchlater'] as num?)?.toInt() ?? 0,
    localNovels: (simSetup['localNovels'] as num?)?.toInt() ?? 0,
    downloadSingles: (simSetup['downloadSingles'] as num?)?.toInt() ?? 0,
  );
}

Future<void> _runCatalogActions(
  FilmRecorder film,
  GoRouter router,
  ReviewWorld world,
  Map<String, dynamic> item, {
  required bool isPointer,
}) async {
  final baseTarget = (item['target'] as Map).cast<String, dynamic>();
  final actions = (item['actions'] as List).cast<Map<String, dynamic>>();

  for (final step in actions) {
    final type = step['type'] as String;
    final stepTarget =
        (step['target'] as Map?)?.cast<String, dynamic>() ?? baseTarget;
    final optional = step['optional'] == true;

    if (type == 'wait_ms') {
      final ms = (step['ms'] as num?)?.toInt() ?? 300;
      await film.frames((ms / 50).round().clamp(2, 12));
      continue;
    }
    if (type == 'navigate') {
      final dest = (step['sim_path'] ?? step['path']).toString();
      router.go(dest);
      await settleReview(film.tester, limit: const Duration(seconds: 4));
      await film.frames(3);
      continue;
    }
    if (type == 'fault') {
      if (step['reset'] == true) {
        // Restore normal recommended responder on ReviewWorld so retry recovers.
        world.responders['/v1/illust/recommended'] = (url) {
          final offset = int.parse(url.queryParameters['offset'] ?? '0');
          return reviewJson({
            'illusts': [
              for (var i = 0; i < 12; i++)
                reviewIllustJson(
                  1000 + offset + i,
                  pageCount: (1000 + offset + i).isEven ? 3 : 1,
                ),
            ],
            'next_url': null,
          })(url);
        };
      }
      continue;
    }
    if (type == 'resize_window') {
      final w = (step['width'] as num).toDouble();
      final h = (step['height'] as num).toDouble();
      final dpr = film.tester.view.devicePixelRatio;
      film.tester.view.physicalSize = Size(w * dpr, h * dpr);
      await film.frames(4);
      continue;
    }
    if (type == 'key') {
      await _sendSimKey(film, step['key']?.toString() ?? '');
      await film.frames(3);
      continue;
    }
    if (type == 'type_text') {
      final editable = find.byType(EditableText);
      if (editable.evaluate().isNotEmpty) {
        await film.tester.enterText(
          editable.first,
          step['text']?.toString() ?? '',
        );
        await film.frames(3);
      }
      continue;
    }

    var pt = _resolveSimPoint(film.tester, stepTarget, step);
    if (pt == null && type == 'scroll' && step['target'] == null) {
      final viewSize =
          film.tester.view.physicalSize / film.tester.view.devicePixelRatio;
      pt = Offset(viewSize.width * 0.5, viewSize.height * 0.55);
    }
    if (pt == null) {
      if (optional) continue;
      throw StateError('Locator not found on screen: $stepTarget');
    }

    if (type == 'tap' || type == 'click') {
      await _simTap(film, pt, isPointer: isPointer);
    } else if (type == 'double_click') {
      await _simTap(film, pt, isPointer: isPointer);
      await film.frames(2);
      await _simTap(film, pt, isPointer: isPointer);
    } else if (type == 'long_press' ||
        type == 'right_click' ||
        type == 'context_action') {
      if (isPointer) {
        final g = await film.tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await g.down(pt, timeStamp: film.clock);
        await film.frames(3);
        await g.up(timeStamp: film.clock);
        await film.untilSettled(max: 24);
      } else {
        final g = await film.tester.createGesture();
        await g.down(pt, timeStamp: film.clock);
        await film.frames(FilmRecorder.longPressFrames);
        await g.up(timeStamp: film.clock);
        await film.untilSettled(max: 24);
      }
    } else if (type == 'hover') {
      if (isPointer) {
        final g = await film.tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await g.addPointer(location: pt);
        await g.moveTo(pt, timeStamp: film.clock);
        await film.frames(6);
        await g.removePointer();
      } else {
        await film.frames(4);
      }
    } else if (type == 'scroll') {
      final dy = (step['dy'] as num?)?.toDouble() ?? -240;
      if (isPointer) {
        film.tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: pt,
            scrollDelta: Offset(0, -dy),
            timeStamp: film.clock,
          ),
        );
        await film.frames(5);
      } else {
        await _simDrag(
          film,
          pt,
          Offset(0, dy),
          isPointer: false,
          holdBeforeUp: true,
        );
      }
    } else if (type == 'drag' || type == 'swipe') {
      final size =
          film.tester.view.physicalSize / film.tester.view.devicePixelRatio;
      final dx = ((step['dx_ratio'] as num?)?.toDouble() ?? 0.0) * size.width;
      final dy = ((step['dy_ratio'] as num?)?.toDouble() ?? 0.0) * size.height;
      await _simDrag(film, pt, Offset(dx, dy), isPointer: isPointer);
    }
  }
}

Offset? _resolveSimPoint(
  WidgetTester tester,
  Map<String, dynamic> target,
  Map<String, dynamic> step,
) {
  final viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final ox =
      (step['offset_x_ratio'] as num?)?.toDouble() ??
      (target['offset_x_ratio'] as num?)?.toDouble() ??
      0.5;
  final oy =
      (step['offset_y_ratio'] as num?)?.toDouble() ??
      (target['offset_y_ratio'] as num?)?.toDouble() ??
      0.5;

  final kind = target['kind']?.toString() ?? 'viewport_ratio';
  if (kind == 'viewport_ratio') {
    final rx = (target['x_ratio'] as num?)?.toDouble() ?? 0.5;
    final ry = (target['y_ratio'] as num?)?.toDouble() ?? 0.5;
    return Offset(
      (viewSize.width * rx).clamp(2.0, viewSize.width - 2.0),
      (viewSize.height * ry).clamp(2.0, viewSize.height - 2.0),
    );
  }

  final queries = switch (kind) {
    'key' || 'semantics' || 'text' => [target['query']?.toString() ?? ''],
    'any_key' || 'any_semantics' || 'any_text' =>
      ((target['queries'] as List?) ?? const []).map((e) => '$e').toList(),
    _ => const <String>[],
  };
  final baseKind = kind.replaceFirst('any_', '');
  for (final q in queries) {
    if (q.isEmpty) continue;
    final finder = switch (baseKind) {
      'key' => find.byKey(Key(q)),
      'semantics' => _eitherFinder(
        _eitherFinder(find.bySemanticsLabel(q), find.byTooltip(q)),
        _eitherFinder(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.tooltip == q,
          ),
          find.bySemanticsLabel(RegExp(RegExp.escape(q))),
        ),
      ),
      'text' => _eitherFinder(
        _eitherFinder(find.text(q), find.textContaining(q)),
        find.bySemanticsLabel(RegExp(RegExp.escape(q))),
      ),
      _ => find.byWidgetPredicate((_) => false),
    };
    final hit = finder.hitTestable();
    final effective = hit.evaluate().isNotEmpty ? hit : finder;
    if (effective.evaluate().isNotEmpty) {
      final count = effective.evaluate().length;
      for (var i = 0; i < count; i++) {
        final rect = tester.getRect(effective.at(i));
        final c = rect.center;
        if (c.dx >= 0 &&
            c.dx <= viewSize.width &&
            c.dy >= 0 &&
            c.dy <= viewSize.height) {
          return Offset(
            (rect.left + rect.width * ox).clamp(1.0, viewSize.width - 1.0),
            (rect.top + rect.height * oy).clamp(1.0, viewSize.height - 1.0),
          );
        }
      }
    }
  }
  return null;
}

Finder _eitherFinder(Finder a, Finder b) => a.evaluate().isNotEmpty ? a : b;

Future<void> _simTap(
  FilmRecorder film,
  Offset pt, {
  required bool isPointer,
}) async {
  final g = await film.tester.createGesture(
    kind: isPointer ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
  );
  await g.down(pt, timeStamp: film.clock);
  await film.frames(2);
  await g.up(timeStamp: film.clock);
  await film.untilSettled(max: 24, quiet: 4);
}

Future<void> _simDrag(
  FilmRecorder film,
  Offset start,
  Offset delta, {
  required bool isPointer,
  bool holdBeforeUp = false,
}) async {
  final viewSize =
      film.tester.view.physicalSize / film.tester.view.devicePixelRatio;
  if (!isPointer && delta.distance > 320.0) {
    final chunks = (delta.distance / 280.0).ceil();
    final chunkDelta = delta / chunks.toDouble();
    final safeStart = Offset(
      start.dx.clamp(12.0, viewSize.width - 12.0),
      delta.dy < 0
          ? start.dy.clamp(viewSize.height * 0.45, viewSize.height * 0.82)
          : start.dy.clamp(viewSize.height * 0.18, viewSize.height * 0.55),
    );
    for (var c = 0; c < chunks; c++) {
      await _simDrag(
        film,
        safeStart,
        chunkDelta,
        isPointer: false,
        holdBeforeUp: holdBeforeUp,
      );
    }
    return;
  }
  final g = await film.tester.createGesture(
    kind: isPointer ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
  );
  await g.down(start, timeStamp: film.clock);
  const steps = 8;
  final stepDelta = delta / steps.toDouble();
  for (var i = 0; i < steps; i++) {
    await g.moveBy(stepDelta, timeStamp: film.clock + FilmRecorder.vsync);
    await film.frame();
  }
  if (holdBeforeUp) {
    // Pause before finger lift so scroll actions move deterministically without fling overshoot.
    await film.frames(5);
  }
  await g.up(timeStamp: film.clock);
  await film.untilSettled(max: 24, quiet: 4);
}

Future<void> _sendSimKey(FilmRecorder film, String name) async {
  if (name == 'Escape') {
    await film.tester.sendKeyEvent(LogicalKeyboardKey.escape);
  } else if (name == 'F11') {
    await film.tester.sendKeyEvent(LogicalKeyboardKey.f11);
  } else if (name == 'Left') {
    await film.tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  } else if (name == 'Right') {
    await film.tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  } else if (name == 'Space') {
    await film.tester.sendKeyEvent(LogicalKeyboardKey.space);
  } else if (name == 'Ctrl+K' || name == 'Cmd+K') {
    await film.tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await film.tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await film.tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  } else if (name == 'Alt+Left') {
    await film.tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await film.tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await film.tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }
}
