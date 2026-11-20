import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/dev_workbench/dev_workbench_bridge.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/dev_transport_override.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';

import '../helpers/fake_account.dart';
import '../helpers/image_network.dart';
import '../helpers/waits.dart';

void main() {
  testWidgets(
    'DevWorkbenchHost validates commands, tracks pushed routes, non-client regions, top-most findBounds, and cleans synthetic loopback account on live switch',
    (tester) async {
      const channel = MethodChannel(kDesktopWindowChannelName);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final windowHost = MethodChannelDesktopWindowHost();
      addTearDown(windowHost.dispose);

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => Column(
              children: [
                const Text('DuplicateLabel', key: ValueKey('shared_key')),
                const Offstage(
                  offstage: true,
                  child: Text(
                    'HiddenOffstage',
                    key: ValueKey('hidden_offstage'),
                  ),
                ),
                const Visibility(
                  visible: false,
                  maintainState: true,
                  child: Text('HiddenVis', key: ValueKey('hidden_vis')),
                ),
                const TickerMode(
                  enabled: false,
                  child: Text('HiddenTicker', key: ValueKey('hidden_ticker')),
                ),
                Text.rich(
                  const TextSpan(
                    text: 'Rich',
                    children: [TextSpan(text: 'Label')],
                  ),
                  key: const ValueKey('rich_key'),
                ),
              ],
            ),
          ),
          GoRoute(
            path: '/illust/:id',
            builder: (_, state) => Align(
              alignment: Alignment.bottomRight,
              child: Text(
                'DuplicateLabel',
                key: ValueKey(
                  state.pathParameters['id'] == '900001'
                      ? 'shared_key'
                      : 'target_title',
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      final hostKey = GlobalKey<DevWorkbenchHostState>();
      final options = DevClientOptions(
        profileName: 'wb',
        initialSourceMode: DevDataSourceMode.loopback,
        loopbackOrigin: Uri.parse('http://127.0.0.1:18490'),
        freshOnboarding: true,
        exposeVmExtensions: false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...accountProviderOverrides(),
            imageWorkerProvider.overrideWithValue(stalledImageWorker()),
            desktopWindowHostProvider.overrideWithValue(windowHost),
            devTransportProvider.overrideWith(
              () => DevTransportNotifier(options.initialTransportConfig),
            ),
          ],
          child: DevWorkbenchHost(
            key: hostKey,
            router: router,
            options: options,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pump();

      final state = hostKey.currentState!;
      await expectLater(
        state.dispatchDebugCommand('navigate', {'path': 'https://evil.com'}),
        throwsArgumentError,
      );
      await expectLater(
        state.dispatchDebugCommand('navigate', {'path': '/foo/../secret'}),
        throwsArgumentError,
      );

      // Report non-client regions and verify snapshot outputs window + nonClientRegions.
      await windowHost.setTitleBarMetrics(
        titleBarHeight: 36,
        regions: const [
          DesktopTitleBarRegion(
            rect: Rect.fromLTWH(0, 0, 600, 36),
            kind: 'caption',
          ),
          DesktopTitleBarRegion(
            rect: Rect.fromLTWH(600, 0, 46, 36),
            kind: 'maximize',
          ),
        ],
      );

      // Offstage / Visibility(false) / TickerMode(false) must be ignored; Text.rich matches.
      expect(
        (await state.dispatchDebugCommand('findBounds', {
          'kind': 'text',
          'query': 'HiddenOffstage',
        }))['found'],
        isFalse,
      );
      expect(
        (await state.dispatchDebugCommand('findBounds', {
          'kind': 'text',
          'query': 'HiddenVis',
        }))['found'],
        isFalse,
      );
      expect(
        (await state.dispatchDebugCommand('findBounds', {
          'kind': 'text',
          'query': 'HiddenTicker',
        }))['found'],
        isFalse,
      );
      expect(
        (await state.dispatchDebugCommand('findBounds', {
          'kind': 'text',
          'query': 'RichLabel',
        }))['found'],
        isTrue,
      );

      final baseBounds = await state.dispatchDebugCommand('findBounds', {
        'kind': 'key',
        'query': 'shared_key',
      });
      expect(baseBounds['found'], isTrue);

      // Push route onto stack: snapshot['route'] reflects top pushed location and
      // findBounds picks the top-most painted match instead of the occluded page underneath.
      unawaited(router.push('/illust/900001'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final snap = await state.dispatchDebugCommand('snapshot');
      expect(snap['route'], '/illust/900001');
      final nonClient = snap['nonClientRegions'] as Map<String, Object?>;
      expect(nonClient['titleBarHeight'], 36.0);
      expect((nonClient['dragRegions'] as List), hasLength(1));
      expect((nonClient['interactiveRegions'] as List), hasLength(1));
      expect((snap['window'] as Map<String, Object?>)['titleBarHeight'], 36.0);

      final topBounds = await state.dispatchDebugCommand('findBounds', {
        'kind': 'key',
        'query': 'shared_key',
      });
      expect(topBounds['found'], isTrue);
      expect((topBounds['y'] as num) > (baseBounds['y'] as num), isTrue);

      // Loopback sign-in writes synthetic 900001 account; switching to live clears it.
      Map<String, Object?>? signInRes;
      unawaited(
        state
            .dispatchDebugCommand('loopbackSignIn')
            .then((res) => signInRes = res),
      );
      await pumpUntil(tester, () => signInRes != null);
      expect(signInRes!['accountId'], '900001');
      final afterSignIn = await state.dispatchDebugCommand('snapshot');
      expect(afterSignIn['hasUsableAccount'], isTrue);

      Map<String, Object?>? liveRes;
      unawaited(
        state
            .dispatchDebugCommand('setSourceMode', {'mode': 'live'})
            .then((res) => liveRes = res),
      );
      await pumpUntil(tester, () => liveRes != null);
      final afterLive = await state.dispatchDebugCommand('snapshot');
      expect(afterLive['sourceMode'], 'live');
      expect(afterLive['hasUsableAccount'], isFalse);

      await expectLater(
        state.dispatchDebugCommand('loopbackSignIn'),
        throwsStateError,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
