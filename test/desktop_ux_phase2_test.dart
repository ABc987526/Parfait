import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show SelectionRegistrar, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/app.dart' show AppChrome;
import 'package:parfait/app/clipboard.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/layout/window_layout_spec.dart'
    show WindowEnvironmentOverride;
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/app/navigation/forward_history.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/navigation/routes.dart' show IllustRouteExtra;
import 'package:parfait/app/person_avatar.dart';
import 'package:parfait/app/touch_exploration_scope.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/comment_composer.dart';
import 'package:parfait/app/widgets/feed/feed_selection.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/page_header.dart';
import 'package:parfait/app/widgets/search_field_button.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/widgets/smooth_wheel_scroll.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/app/window/desktop_command_bar.dart';
import 'package:parfait/app/window/desktop_menu_bar.dart';
import 'package:parfait/app/window/desktop_title_bar.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/platform/accessibility.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';
import 'package:parfait/core/platform/image_clipboard.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/home/home_page.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart'
    show DetailPageImage;
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/api_responses.dart';
import 'helpers/bookmark_world.dart';
import 'helpers/card_world.dart';
import 'helpers/comment_world.dart';
import 'helpers/connectivity_channels.dart';
import 'helpers/detail_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_detail_page_support.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';

void _collectMenuItems(
  List<PlatformMenuItem> items,
  List<PlatformMenuItem> out,
) {
  for (final item in items) {
    out.add(item);
    switch (item) {
      case PlatformMenu(:final menus):
        _collectMenuItems(menus, out);
      case PlatformMenuItemGroup(:final members):
        _collectMenuItems(members, out);
      case _:
        break;
    }
  }
}

Future<void> _sendKeyChord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? modifier,
}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
}

Future<Object?> _invokeNavCommand(String method) async {
  const codec = StandardMethodCodec();
  final completer = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'parfait/navigation_commands',
        codec.encodeMethodCall(MethodCall(method)),
        completer.complete,
      );
  final reply = await completer.future;
  return reply == null ? null : codec.decodeEnvelope(reply);
}

SelectionRegistrar? _registrarOfRichText(
  WidgetTester tester,
  Finder richTextFinder,
) => tester.widget<RichText>(richTextFinder).selectionRegistrar;

Finder _richTextFor(String text) =>
    find.descendant(of: find.text(text).first, matching: find.byType(RichText));

void main() {
  testWidgets(
    'DesktopCommandBar chrome, drag regions, header deduplication, and popovers',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        const altAccount = Account(id: '200', userId: 200, name: 'alt');
        await seedAccounts([
          testerAccount,
          altAccount,
        ], currentId: testerAccount.id);
        final credStore = FakeCredentialStore()
          ..seed(
            testerAccount.id,
            const Credential(accessToken: 'a1', refreshToken: 'r1'),
          )
          ..seed(
            altAccount.id,
            const Credential(accessToken: 'a2', refreshToken: 'r2'),
          );
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (context, _) => BranchRootScope(
                branchIndex: 0,
                child: Row(
                  children: [
                    SizedBox(
                      width: ShellRail.width,
                      child: ShellRail(
                        destinations: const [
                          FuncBottomNavDestination(
                            icon: Icons.home_outlined,
                            label: 'Home',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        form: FormFactor.pc,
                        expanded: false,
                        onToggle: () {},
                        onBookmarks: () {},
                        onDownloads: () {},
                      ),
                    ),
                    const Expanded(
                      child: Row(
                        children: [
                          HeaderSearch(type: SearchResultType.illust),
                          HeaderRefresh(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);

        List<DesktopTitleBarRegion> lastRegions = const [];
        double? lastHeight;
        final commandScope = ValueNotifier<bool>(true);
        addTearDown(commandScope.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: accountProviderOverrides(credentialStore: credStore),
            child: ValueListenableBuilder<bool>(
              valueListenable: commandScope,
              builder: (context, active, _) => localizedRouterApp(
                router,
                builder: (ctx, child) => promptHostBuilder(
                  ctx,
                  DesktopChromeMetrics(
                    titleBarHeight: kDesktopCommandBarHeight,
                    usesSystemTitleBar: false,
                    showCustomButtons: true,
                    hostMetrics: const DesktopWindowPlatformMetrics(),
                    actions: DesktopWindowActions(
                      onMinimize: () {},
                      onToggleMaximize: () {},
                      onClose: () {},
                      onToggleFullScreen: () {},
                      onStartDragging: () {},
                      onTitleBarDoubleClick: () {},
                      onRegionsChanged: (r) => lastRegions = r,
                      onRegionsWithHeightChanged: (r, h) {
                        lastRegions = r;
                        lastHeight = h;
                      },
                    ),
                    child: DesktopCommandBarScope(
                      active: active,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (active)
                            DesktopCommandBar(
                              settings: AppSettings.defaults(),
                              router: router,
                            ),
                          Expanded(child: child!),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final bar = find.byKey(const Key('desktop-command-bar'));
        expect(tester.getSize(bar).height, kDesktopCommandBarHeight);
        expect(lastHeight, kDesktopCommandBarHeight);
        expect(lastRegions.where((r) => r.kind == 'caption'), hasLength(2));
        expect(lastRegions.where((r) => r.kind == 'maximize'), hasLength(1));

        // Header deduplication: ShellRail header + HeaderSearch + HeaderRefresh collapse.
        expect(
          find.descendant(
            of: find.byType(ShellRail),
            matching: find.byIcon(AppIcons.sidebarExpand),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderRefresh),
            matching: find.byType(IconButton),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderSearch),
            matching: find.byType(SearchFieldButton),
          ),
          findsNothing,
        );

        // Filter popover toggles R-18 and AI filters.
        await tester.tap(find.byKey(const Key('desktop-command-filter')));
        await tester.pumpAndSettle();
        final r18Switch = find.byKey(const Key('desktop-command-filter-r18'));
        expect(r18Switch, findsOneWidget);
        expect(
          find.byKey(const Key('desktop-command-filter-ai')),
          findsOneWidget,
        );
        await tester.tap(r18Switch);
        await tester.pumpAndSettle();
        expect((await storedSettings().load()).enableLocalBlockR18, isTrue);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Account popover lists accounts + settings entry.
        await tester.tap(find.byKey(const Key('desktop-command-account')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('desktop-command-account-${testerAccount.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('desktop-command-account-${altAccount.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('desktop-command-account-settings')),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Turning off DesktopCommandBarScope restores inline header controls.
        commandScope.value = false;
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(ShellRail),
            matching: find.byIcon(AppIcons.sidebarExpand),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderRefresh),
            matching: find.byType(IconButton),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'DesktopMenuBar restricts to macOS and wires View, Navigation, Bookmarks, Downloads, and Search',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => const SizedBox.shrink(),
          ),
        ],
      );
      addTearDown(router.dispose);

      for (final entry in <(TargetPlatform, Matcher)>[
        (TargetPlatform.windows, findsNothing),
        (TargetPlatform.linux, findsNothing),
        (TargetPlatform.macOS, findsOneWidget),
      ]) {
        debugDefaultTargetPlatformOverride = entry.$1;
        try {
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              overrides: [...await signedInAccountOverrides()],
              builder: (_, child) => DesktopMenuBar(
                settings: AppSettings.defaults(),
                router: router,
                child: child!,
              ),
            ),
          );
          await tester.pump();
          expect(
            find.byType(PlatformMenuBar),
            entry.$2,
            reason: 'PlatformMenuBar gating on ${entry.$1}',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      final l10n = lookupAppLocalizations(zhCN);
      final menus = buildDesktopPlatformMenus(
        l10n: l10n,
        router: router,
        railExpanded: false,
        isFullScreen: false,
        onToggleRail: () {},
      );
      final topLabels = [for (final m in menus.cast<PlatformMenu>()) m.label];
      expect(topLabels, [
        'Parfait',
        l10n.menuFile,
        l10n.menuNavigate,
        l10n.menuView,
        l10n.menuWindow,
      ]);
      expect(topLabels, isNot(contains('Edit')));

      final all = <PlatformMenuItem>[];
      _collectMenuItems(menus, all);
      final labels = {for (final item in all) item.label};
      for (final expected in [
        l10n.menuPreferences,
        l10n.railExpand,
        l10n.menuEnterFullScreen,
        l10n.navBack,
        l10n.navForward,
        l10n.refresh,
        l10n.railBookmarks,
        l10n.railDownloads,
        l10n.searchTitle,
      ]) {
        expect(labels, contains(expected));
      }
      final searchItem = all.firstWhere((e) => e.label == l10n.searchTitle);
      expect(
        searchItem.shortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
      );
      final prefsItem = all.firstWhere((e) => e.label == l10n.menuPreferences);
      expect(
        prefsItem.shortcut,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
      );
      expect(HomeDestination.values, hasLength(5));
    },
  );

  testWidgets(
    'ForwardHistoryStack replays per-branch forward entries and debounces mouse back/forward',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        late GoRouter router;
        router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(path: '/recommended', builder: (_, _) => const Text('rec')),
            GoRoute(
              path: '/recommended/work-1',
              builder: (_, _) => const Text('rec-1'),
            ),
            GoRoute(
              path: '/recommended/work-2',
              builder: (_, _) => const Text('rec-2'),
            ),
            GoRoute(path: '/ranking', builder: (_, _) => const Text('rank')),
            GoRoute(
              path: '/ranking/work-9',
              builder: (_, _) => const Text('rank-9'),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          localizedRouterApp(
            router,
            builder: (_, child) => KeyboardBack(router: router, child: child!),
          ),
        );
        await tester.pumpAndSettle();

        final history = ForwardHistoryStack.ofRouter(router);
        unawaited(router.push('/recommended/work-1'));
        await tester.pumpAndSettle();
        expect(find.text('rec-1'), findsOneWidget);
        expect(history.stateListenable.value.canGoBack, isTrue);
        expect(history.stateListenable.value.canGoForward, isFalse);

        // Mouse back pops and records forward entry in recommended bucket.
        final pointer = TestPointer(7, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(const Offset(50, 50)));
        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kBackMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();
        expect(find.text('rec'), findsOneWidget);
        expect(history.stateListenable.value.canGoForward, isTrue);

        // Cross-source debounce within 120ms: hardware pointer nav immediately
        // followed by parfait/navigation_commands channel suppresses duplicate.
        unawaited(router.push('/recommended/work-1'));
        await tester.pumpAndSettle();
        unawaited(router.push('/recommended/work-2'));
        await tester.pumpAndSettle();
        expect(find.text('rec-2'), findsOneWidget);

        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kBackMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await _invokeNavCommand('back');
        await tester.pumpAndSettle();
        // Second cross-source back within 120ms at the same push generation was
        // suppressed: stays on rec-1 instead of popping all the way to rec.
        expect(find.text('rec-1'), findsOneWidget);

        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kForwardMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await _invokeNavCommand('forward');
        await tester.pumpAndSettle();
        expect(find.text('rec-2'), findsOneWidget);

        // Per-branch isolation: switching to /ranking keeps forward stack separated.
        await history.goBack();
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isTrue);

        router.go('/ranking');
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isFalse);

        unawaited(router.push('/ranking/work-9'));
        await tester.pumpAndSettle();
        await history.goBack();
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isTrue);
        expect(await history.goForward(), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('rank-9'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Pointer mode skips PressScale 100ms delay, animates ShellRail fade+slide at 150ms, and SmoothWheelScroll jumps instantly',
    (tester) async {
      // 1. PressScale: mouse presses immediately vs touch waits kPressTimeout.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PressScale(child: Text('card content')),
            ),
          ),
        ),
      );
      double currentScale() {
        final transition = find.descendant(
          of: find.byType(PressScale),
          matching: find.byType(ScaleTransition),
        );
        if (transition.evaluate().isEmpty) return 1.0;
        return tester.widget<ScaleTransition>(transition).scale.value;
      }

      expect(currentScale(), 1.0);
      final pressTarget = tester.getCenter(find.byType(PressScale));
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.down(pressTarget));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(currentScale(), lessThan(1.0));
      await tester.sendEventToBinding(mouse.up());
      await tester.pumpAndSettle();
      expect(currentScale(), closeTo(1.0, 0.001));

      final touch = TestPointer(2, PointerDeviceKind.touch);
      await tester.sendEventToBinding(touch.down(pressTarget));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(currentScale(), 1.0);
      await tester.pump(kPressTimeout);
      await tester.pump(const Duration(milliseconds: 50));
      expect(currentScale(), lessThan(1.0));
      await tester.sendEventToBinding(touch.up());
      await tester.pumpAndSettle();

      // 2. SmoothWheelScroll: instant jumpTo when wheelScroll resolves to Duration.zero.
      final wheelController = ScrollController();
      addTearDown(wheelController.dispose);
      Future<void> pumpWheel({required bool reduce}) => tester.pumpWidget(
        MotionScope(
          reduce: reduce,
          child: MaterialApp(
            home: Scaffold(
              body: SmoothWheelScroll(
                controller: wheelController,
                builder: (_, c, p) => ListView.builder(
                  controller: c,
                  physics: p,
                  itemCount: 100,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 40, child: Text('$i')),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpWheel(reduce: true);
      final wheelPtr = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(wheelPtr.hover(const Offset(200, 200)));
      await tester.pump();
      await tester.sendEventToBinding(wheelPtr.scroll(const Offset(0, 160)));
      await tester.pump();
      expect(wheelController.offset, closeTo(160, 0.5));

      // 3. Desktop HomeBranchStack uses 150ms fade+slide instead of 300ms swipe.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        final router = pixivRouter('/recommended');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...await signedInAccountOverrides(),
              touchExplorationProvider.overrideWith(
                (ref) => const Stream.empty(),
              ),
            ],
            child: localizedRouterApp(
              router,
              builder: (_, child) => FormFactorScope(
                choice: InterfaceForm.auto,
                child: TouchExplorationScope(child: child!),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        router.go('/ranking');
        await tester.pump();
        // Mid-transition before 150ms.
        await tester.pump(const Duration(milliseconds: 70));
        expect(find.byType(RankingPage), findsOneWidget);
        // Settles completely by 150ms (+1 frame) without waiting 300ms.
        await tester.pump(const Duration(milliseconds: 90));
        await tester.pump();
        final rankingSlide = tester.widget<SlideTransition>(
          find
              .ancestor(
                of: find.byType(RankingPage),
                matching: find.byType(SlideTransition),
              )
              .first,
        );
        expect(rankingSlide.position.value, Offset.zero);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'ImageViewer supports wheel zoom with 1.0x snap, multi-page hover scrubber, and wide info panel pop-before-navigate',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        final container = await signedInApiContainer(
          PixivApi().client,
          overrides: [
            imageWorkerProvider.overrideWithValue(stalledImageWorker()),
          ],
        );
        final single = parseIllust(illustJson(10, pageCount: 1));
        final multi = parseIllust(
          illustJson(42, pageCount: 2, withMetaPages: true),
        );

        Future<GoRouter> pumpViewer(IllustEntity entity) async {
          final router = GoRouter(
            initialLocation: '/recommended/viewer',
            routes: [
              GoRoute(
                path: '/recommended',
                builder: (_, _) => const Text('recommended-base'),
                routes: [
                  GoRoute(
                    path: 'viewer',
                    builder: (_, _) => ImageViewerPage(
                      urls: [
                        for (var i = 0; i < entity.pageCount; i++)
                          entity.originalUrlAt(i)!,
                      ],
                      entity: entity,
                    ),
                  ),
                  GoRoute(
                    path: 'user/:id',
                    builder: (_, state) =>
                        Text('user-${state.pathParameters['id']}'),
                  ),
                  GoRoute(
                    path: 'search/results',
                    builder: (_, state) =>
                        Text('search-${state.uri.queryParameters['q']}'),
                  ),
                ],
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              container: container,
              builder: (_, child) => InputModalityScope(child: child!),
            ),
          );
          await tester.pump();
          return router;
        }

        // Single-page omits scrubber; 2-page pointer viewer shows scrubber.
        await pumpViewer(single);
        expect(find.byKey(const Key('viewer-page-scrubber')), findsNothing);

        await pumpViewer(multi);
        expect(find.byKey(const Key('viewer-page-scrubber')), findsOneWidget);

        // Pointer wheel zoom in (>1.0) then zoom out snaps cleanly to 1.0.
        double stageScale() => tester
            .widget<InteractiveViewer>(
              find.byKey(const ValueKey('viewer-page-0')),
            )
            .transformationController!
            .value
            .getMaxScaleOnAxis();

        final pointer = TestPointer(9, PointerDeviceKind.mouse);
        final stageCenter = tester.getCenter(
          find.byKey(const ValueKey('viewer-page-0')),
        );
        await tester.sendEventToBinding(pointer.hover(stageCenter));
        await tester.pump();
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
        await tester.pumpAndSettle();
        expect(stageScale(), greaterThan(1.15));

        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
        await tester.pumpAndSettle();
        expect(stageScale(), closeTo(1.0, 0.001));

        // Open docked 320dp info panel and pop-before-navigate via author link.
        await tester.tap(find.byIcon(AppIcons.info));
        await tester.pumpAndSettle();
        final panel = find.byKey(const Key('viewer-info-panel'));
        expect(panel, findsOneWidget);
        expect(tester.getSize(panel).width, 320);

        await tester.tap(
          find.descendant(of: panel, matching: find.text(multi.user.name)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsNothing);
        expect(find.text('user-${multi.user.id}'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'SelectionArea wraps detail and comments text while excluding IllustCard, collapsed fade, and touch tags',
    (tester) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(
            42,
            pageCount: 1,
            caption: List.filled(18, '这是一段很长的作品说明文本用来触发折叠效果').join('，'),
          ),
        },
        relatedOverrides: {
          42: [illustJson(99, pageCount: 1)],
        },
        commentOverrides: {
          42: [commentJson(sampleComment(11, workId: 42))],
        },
        extraOverrides: [
          imageWorkerProvider.overrideWithValue(stalledImageWorker()),
        ],
      );

      // On Android touch: TagChip is wrapped in SelectionContainer.disabled;
      // ExpandableText's collapsed fade/button stay non-selectable inside SelectionArea.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpDetail(
          tester,
          container,
          seedStore: false,
          illustId: 42,
          pageCount: 1,
          locale: zhCN,
          surface: const Size(600, 900),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byType(ShaderMask).first,
            matching: find.byType(SelectionContainer),
          ),
          findsWidgets,
        );
        expect(
          _registrarOfRichText(tester, _richTextFor('illust 42')),
          isNotNull,
        );
        final tagText = find
            .descendant(
              of: find.byType(TagChip).first,
              matching: find.byType(RichText),
            )
            .first;
        expect(_registrarOfRichText(tester, tagText), isNull);
        expect(
          _registrarOfRichText(
            tester,
            find.descendant(
              of: find.textContaining('展开').first,
              matching: find.byType(RichText),
            ),
          ),
          isNull,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      // CommentsPage wraps list in SelectionArea while keeping CommentComposer outside.
      final commentApi = CommentApi();
      final commentContainer = await signedInApiContainer(
        PixivApi({...backgroundRoutes, ...commentApi.routes}).client,
        account: commentsAccountStore().accounts.single,
        overrides: [
          imageWorkerProvider.overrideWithValue(stalledImageWorker()),
        ],
      );
      await tester.pumpWidget(
        localizedApp(
          container: commentContainer,
          builder: promptHostBuilder,
          home: const CommentsPage(workId: 42),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.text('comment 11'),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(CommentComposer),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );

      // IllustCard's internal column sits under SelectionContainer.disabled even when hosted in SelectionArea,
      // while pointer-mode TagChip remains selectable inside SelectionArea.
      final (cardContainer, _, _) = await makeCardWorld();
      await tester.pumpWidget(
        localizedApp(
          container: cardContainer,
          body: SelectionArea(
            child: IllustCard(entity: parseIllust(illustJson(77))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_registrarOfRichText(tester, _richTextFor('illust 77')), isNull);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          localizedApp(
            container: cardContainer,
            body: SelectionArea(
              child: TagChip(label: 'original', onTap: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pointerTagText = find
            .descendant(
              of: find.byType(TagChip).first,
              matching: find.byType(RichText),
            )
            .first;
        expect(_registrarOfRichText(tester, pointerTagText), isNotNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'SelectableFeedHost gates >=600dp multi-select, Ctrl/Cmd+Click, Shift range, Ctrl+A, Esc, and batch bookmark/download',
    (tester) async {
      final bookmarks = BookmarkApi();
      final actionStore = InMemoryActionStore();
      final container = await signedInApiContainer(
        PixivApi({...backgroundRoutes, ...bookmarks.routes}).client,
        overrides: [
          actionStoreProvider.overrideWithValue(actionStore),
          imageWorkerProvider.overrideWithValue(stalledImageWorker()),
        ],
      );
      final items = [
        parseIllust(illustJson(1)),
        parseIllust(illustJson(2)),
        parseIllust(illustJson(3)),
      ];
      final navigated = <int>[];
      final widthNotifier = ValueNotifier<double>(500);
      addTearDown(widthNotifier.dispose);

      Widget detailStub(GoRouterState state) {
        final id = int.parse(state.pathParameters['id']!);
        navigated.add(id);
        return Text('detail-$id');
      }

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/illust/:id',
            builder: (_, state) => detailStub(state),
          ),
          GoRoute(
            path: '/recommended',
            builder: (context, _) => Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: ValueListenableBuilder<double>(
                  valueListenable: widthNotifier,
                  builder: (context, width, _) => SizedBox(
                    width: width,
                    height: 600,
                    child: SelectableFeedHost(
                      child: Builder(
                        builder: (context) {
                          final sel = FeedSelectionScope.maybeOf(context)!;
                          sel.syncItems(items);
                          return CustomScrollView(
                            slivers: [
                              SliverGrid.count(
                                crossAxisCount: 3,
                                childAspectRatio: 0.72,
                                children: [
                                  for (final entity in items)
                                    FeedSelectableCardDecorator(
                                      entityId: entity.id,
                                      child: IllustCard(entity: entity),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            routes: [
              GoRoute(
                path: 'illust/:id',
                builder: (_, state) => detailStub(state),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      for (final (platform, modifier) in [
        (TargetPlatform.windows, LogicalKeyboardKey.controlLeft),
        (TargetPlatform.macOS, LogicalKeyboardKey.metaLeft),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          navigated.clear();
          bookmarks.adds.clear();
          widthNotifier.value = 500;
          setViewSize(tester, const Size(1280, 800));
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              container: container,
              builder: (ctx, child) => promptHostBuilder(
                ctx,
                KeyboardBack(router: router, child: child!),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Narrow (<600dp): Ctrl/Cmd+A and Ctrl/Cmd+Click do not select; card navigates.
          await _sendKeyChord(
            tester,
            LogicalKeyboardKey.keyA,
            modifier: modifier,
          );
          await tester.pump();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);
          await tester.sendKeyDownEvent(modifier);
          await tester.tap(find.byType(IllustCard).at(0));
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);
          expect(navigated, [1]);
          router.pop();
          await tester.pumpAndSettle();

          // Wide (>=600dp): Ctrl/Cmd+Click enters selection mode.
          widthNotifier.value = 800;
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(modifier);
          await tester.tap(find.byType(IllustCard).at(0));
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('feed-batch-action-bar')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('feed-select-badge-1')), findsOneWidget);

          // Shift+Click selects inclusive range [0..2].
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.tap(find.byType(IllustCard).at(2));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
          expect(find.textContaining('3'), findsWidgets);

          // Escape clears active selection without popping route.
          await _sendKeyChord(tester, LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('feed-batch-action-bar')), findsNothing);

          // Ctrl/Cmd+A selects all loaded cards.
          await _sendKeyChord(
            tester,
            LogicalKeyboardKey.keyA,
            modifier: modifier,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('feed-batch-action-bar')),
            findsOneWidget,
          );

          if (platform == TargetPlatform.windows) {
            // Enqueue batch public bookmarks -> durable ActionQueue entries.
            bookmarks.addGate = Completer<void>();
            await tester.tap(
              find.text(lookupAppLocalizations(zhCN).batchBookmarkPublic),
            );
            await tester.pumpAndSettle();
            final queuedRows = await actionStore.listFor(testerAccount.id);
            expect(
              queuedRows.where((r) => r.type == ActionTypes.bookmarkAdd),
              hasLength(3),
            );
            bookmarks.addGate!.complete();
            await tester.pumpAndSettle();
            expect(bookmarks.adds.map((e) => e.$1).toSet(), {1, 2, 3});
            expect(
              find.byKey(const Key('feed-batch-action-bar')),
              findsNothing,
            );
          } else {
            // Clear selection on macOS iteration before next loop.
            await _sendKeyChord(tester, LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );

  testWidgets(
    'Pointer IllustCard keeps immediate PressScale, omits touch long-press, and uses subtle hover highlight without duplicate pills',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (container, _, _) = await makeCardWorld();
        final entity = parseIllust(illustJson(88));
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: (ctx, child) =>
                promptHostBuilder(ctx, InputModalityScope(child: child!)),
            body: Center(
              child: SizedBox(width: 220, child: IllustCard(entity: entity)),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PressScale),
          ),
          findsOneWidget,
        );
        final detector = tester.widget<GestureDetector>(
          find
              .descendant(
                of: find.byType(IllustCard),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(detector.onLongPress, isNull);

        // Hover highlights the card border/overlay without duplicating footer controls.
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PersonAvatar),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.text(entity.user.name),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(BookmarkSwitchButton),
          ),
          findsOneWidget,
        );
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(
          pointer.hover(tester.getCenter(find.byType(IllustCard))),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(PersonAvatar),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.text(entity.user.name),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(IllustCard),
            matching: find.byType(BookmarkSwitchButton),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'ImageClipboard channel and copy-image action copy original bytes with desktop-only gating and deferAppSnackBar',
    (tester) async {
      for (final (platform, expected) in [
        (TargetPlatform.windows, true),
        (TargetPlatform.macOS, true),
        (TargetPlatform.linux, true),
        (TargetPlatform.android, false),
        (TargetPlatform.iOS, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(
            isDesktopImageClipboardSupported,
            expected,
            reason: 'desktop image clipboard gating on $platform',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        const channel = MethodChannel('parfait/image_clipboard');
        final copiedPayloads = <Uint8List>[];
        var channelResult = true;
        Completer<bool>? pendingReply;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'copyImage') {
                final args = call.arguments as Map<dynamic, dynamic>;
                copiedPayloads.add(args['bytes'] as Uint8List);
                if (pendingReply case final pending?) {
                  return pending.future;
                }
                return channelResult;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final worker = inProcessImageWorker(
          () => MockClient((_) async => http.Response.bytes(onePixelPng, 200)),
        );
        final (container, _, _) = await makeWorld(
          extraOverrides: [imageWorkerProvider.overrideWithValue(worker)],
        );
        final entity = parseIllust(
          illustJson(42, pageCount: 1, withMetaSinglePage: true),
        );
        final mountHost = ValueNotifier<bool>(true);
        addTearDown(mountHost.dispose);
        BuildContext? openerContext;

        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: promptHostBuilder,
            body: ValueListenableBuilder<bool>(
              valueListenable: mountHost,
              builder: (context, show, _) => show
                  ? Builder(
                      builder: (inner) {
                        openerContext = inner;
                        return const Text('opener');
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        // Unmount opener mid-flight: deferAppSnackBar still lands on PromptHost.
        pendingReply = Completer<bool>();
        unawaited(
          copyIllustOriginalImageToClipboard(openerContext!, container, entity),
        );
        await pumpIoUntil(tester, () => copiedPayloads.length == 1);
        mountHost.value = false;
        await tester.pump();
        pendingReply.complete(true);
        pendingReply = null;
        await tester.pump();
        await tester.pumpAndSettle();
        expect(copiedPayloads, hasLength(1));
        expect(copiedPayloads.single, orderedEquals(onePixelPng));
        expect(
          find.text(lookupAppLocalizations(zhCN).imageCopiedToClipboard),
          findsOneWidget,
        );

        // Failed native copy reports imageCopyFailed cleanly.
        await tester.pump(const Duration(seconds: 5));
        mountHost.value = true;
        await tester.pump();
        channelResult = false;
        unawaited(
          copyIllustOriginalImageToClipboard(openerContext!, container, entity),
        );
        await pumpIoUntil(tester, () => copiedPayloads.length == 2);
        await tester.pumpAndSettle();
        expect(
          find.text(lookupAppLocalizations(zhCN).imageCopyFailed),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'AppChrome isolates Router BlockSemantics so DesktopCommandBar remains reachable in semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await seedSettings(AppSettings.defaults());
        await seedAccounts([testerAccount], currentId: testerAccount.id);
        final credStore = FakeCredentialStore(
          values: {
            testerAccount.id: const Credential(
              accessToken: 't',
              refreshToken: 'r',
            ),
          },
        );
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const Scaffold(body: Text('home body')),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          localizedRouterApp(
            router,
            overrides: accountProviderOverrides(credentialStore: credStore),
            builder: (context, child) => AppChrome(
              settings: AppSettings.defaults(),
              router: router,
              child: child!,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final refresh = find.byKey(const Key('desktop-command-refresh'));
        expect(refresh, findsOneWidget);
        final node = tester.getSemantics(refresh);
        expect(node.flagsCollection.isButton, isTrue);
        final rootNode = tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!;
        var reachedButtonFromRoot = false;
        var foundRefreshTooltip = false;
        bool visit(SemanticsNode current) {
          if (current.id == node.id) {
            reachedButtonFromRoot = true;
          }
          if (current.tooltip.isNotEmpty) {
            foundRefreshTooltip = true;
          }
          current.visitChildren(visit);
          return true;
        }

        visit(rootNode);
        expect(reachedButtonFromRoot, isTrue);
        expect(foundRefreshTooltip, isTrue);
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'wide AppChrome keeps HomePage element and state mounted across ImageViewerPage push and pop',
    (tester) async {
      answerConnectivityChannels();
      for (final platform in const [
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          setViewSize(tester, const Size(1280, 800));
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          await seedSettings(AppSettings.defaults());
          final (container, _, _) = await makeWorld();
          final entity = parseIllust(illustJson(42));
          container.read(illustStoreProvider).mergeAll([entity]);
          final router = pixivRouter('/recommended');
          final metrics = platform == TargetPlatform.macOS
              ? const DesktopWindowPlatformMetrics(
                  usesSystemTitleBar: false,
                  trafficLightWidth: 78,
                  trafficLightHeight: 16,
                )
              : const DesktopWindowPlatformMetrics(usesSystemTitleBar: false);

          await tester.pumpWidget(
            localizedRouterApp(
              router,
              container: container,
              builder: (context, child) => WindowEnvironmentOverride(
                displaySize: const Size(1280, 800),
                targetPlatform: platform,
                desktopMetrics: metrics,
                desktopActions: DesktopWindowActions.noop,
                showSimulatedTrafficLights: platform == TargetPlatform.macOS,
                child: AppChrome(
                  settings: AppSettings.defaults(),
                  router: router,
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final homeElement = tester.element(find.byType(HomePage));
          final homeState = tester.state(find.byType(HomePage));
          expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);

          unawaited(
            router.push<void>(
              '/recommended/illust/42',
              extra: IllustRouteExtra(entity: entity, heroScope: 'feed'),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byType(DetailPageImage).first);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsOneWidget);
          expect(find.byKey(const Key('desktop-command-bar')), findsNothing);
          expect(
            tester.element(find.byType(HomePage, skipOffstage: false)),
            same(homeElement),
            reason: '$platform HomePage element identity while viewer open',
          );
          expect(
            tester.state(find.byType(HomePage, skipOffstage: false)),
            same(homeState),
            reason: '$platform HomePage state identity while viewer open',
          );

          await tester.tap(find.byType(BackButton).last);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsNothing);
          expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);
          expect(
            tester.element(find.byType(HomePage)),
            same(homeElement),
            reason: '$platform HomePage element identity after viewer close',
          );
          expect(
            tester.state(find.byType(HomePage)),
            same(homeState),
            reason: '$platform HomePage state identity after viewer close',
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );
}
