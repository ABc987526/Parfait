import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/app.dart' show AppChrome;
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/window_layout_spec.dart'
    show WindowEnvironmentOverride;
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/widgets/skeleton/list_skeletons.dart';
import 'package:parfait/app/window/desktop_command_bar.dart';
import 'package:parfait/app/window/desktop_title_bar.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/illust/recommended_repository.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:parfait/features/settings/pages/download_destination_page.dart';
import 'package:parfait/features/settings/pages/theme_settings_page.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/detail_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';
import 'helpers/view_size.dart';

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    answerConnectivityChannels();
  });

  testWidgets(
    'DownloadDestinationPage hides SAF on iOS and shows desktop folder copy and macOS bookmark label',
    (tester) async {
      setViewSize(tester, const Size(800, 1200));
      Future<void> pumpPlatform(
        TargetPlatform platform, [
        AppSettings? s,
      ]) async {
        await seedSettings(s ?? baseTestSettings());
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          localizedApp(
            overrides: const [],
            builder: promptHostBuilder,
            home: const DownloadDestinationPage(),
          ),
        );
        await tester.pumpAndSettle();
      }

      try {
        await pumpPlatform(TargetPlatform.iOS);
        expect(find.text('相册'), findsOneWidget);
        expect(find.text('文件夹（系统目录选择）'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        const fakeBookmark = 'Ym9va21hcmtfbWFjb3Nfc2FuZGJveF90b2tlbg==';
        await pumpPlatform(
          TargetPlatform.macOS,
          baseTestSettings().copyWith(
            downloadDestination: const DownloadDestination.safFolder(
              fakeBookmark,
            ),
          ),
        );
        for (final label in const [
          '默认文件夹',
          '自定义子文件夹名称',
          '自定义目录（系统目录选择）',
          '已授权目录（macOS 沙盒书签）',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text(fakeBookmark), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Setting.available and ThemeSettingsPage adapt haptics and system colors on iOS',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(Setting.hapticStrength.available, isTrue);
        expect(Setting.followSystemColors.available, isFalse);
        expect(Setting.saveLocationSafFolder.available, isFalse);

        await seedSettings(baseTestSettings());
        await tester.pumpWidget(
          localizedApp(
            overrides: const [],
            builder: promptHostBuilder,
            home: const ThemeSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('跟随系统取色'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'DetailImagePager supports hover arrows, mouse wheel, and unfocused arrow keys',
    (tester) async {
      setViewSize(tester, const Size(1400, 900));
      final detailJson = {
        for (final id in const [42, 43])
          id: illustJson(id, pageCount: 3, withMetaPages: true),
      };
      final (container, _, _) = await makeWorld(detailOverrides: detailJson);
      container.read(illustStoreProvider).mergeAll([
        for (final json in detailJson.values) parseIllust(json),
      ]);
      await tester.pumpWidget(
        localizedApp(
          container: container,
          home: IllustDetailPagerPage(
            source: IllustPagerSource()..update(const [42, 43]),
            initialIllustId: 42,
          ),
        ),
      );
      await tester.pumpAndSettle();

      double pageOf(Finder f) => tester.widget<PageView>(f).controller!.page!;
      final innerPager = find.descendant(
        of: find.byType(DetailImagePager),
        matching: find.byType(PageView),
      );
      final nextBtn = find.byKey(const Key('detail-pager-next'));
      final prevBtn = find.byKey(const Key('detail-pager-prev'));
      expect(prevBtn, findsNothing);
      expect(nextBtn, findsOneWidget);
      double nextAlpha() => tester
          .widget<AnimatedOpacity>(
            find.ancestor(of: nextBtn, matching: find.byType(AnimatedOpacity)),
          )
          .opacity;
      expect(nextAlpha(), 0.0);

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(tester.getCenter(find.byType(DetailImagePager))),
      );
      await tester.pumpAndSettle();
      expect(nextAlpha(), 1.0);

      Future<void> step(Future<void> Function() act, double page) async {
        await act();
        await tester.pumpAndSettle();
        expect(pageOf(innerPager), page);
      }

      await step(() => tester.tap(nextBtn), 1.0);
      expect(prevBtn, findsOneWidget);
      await step(() => tester.tap(prevBtn), 0.0);
      await step(
        () => tester.sendEventToBinding(mouse.scroll(const Offset(0, 120))),
        1.0,
      );
      await step(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowRight), 2.0);
      await step(() => tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft), 1.0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(pageOf(find.byType(PageView).first), 1.0);
    },
  );

  testWidgets(
    'AppChrome hides DesktopCommandBar for touch form, provides Tooltip Overlay, and ShellRail keeps shortcuts',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        final accountOverrides = await signedInAccountOverrides();
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const Scaffold(body: Text('home')),
            ),
          ],
        );
        addTearDown(router.dispose);

        Future<void> pumpWithForm(InterfaceForm form) async {
          final settings = AppSettings.defaults().copyWith(interfaceForm: form);
          await seedSettings(settings);
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              overrides: accountOverrides,
              builder: (_, child) => WindowEnvironmentOverride(
                displaySize: const Size(1280, 800),
                targetPlatform: TargetPlatform.windows,
                desktopActions: DesktopWindowActions.noop,
                child: AppChrome(
                  settings: settings,
                  router: router,
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpWithForm(InterfaceForm.touch);
        expect(find.byKey(const Key('desktop-command-bar')), findsNothing);

        await pumpWithForm(InterfaceForm.auto);
        expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);
        final refresh = find.byKey(const Key('desktop-command-refresh'));
        expect(
          find.ancestor(of: refresh, matching: find.byType(Overlay)),
          findsWidgets,
        );
        expect(tester.widget<IconButton>(refresh).tooltip, isNotEmpty);

        await tester.pumpWidget(
          localizedApp(
            body: DesktopCommandBarScope(
              active: true,
              child: ShellRail(
                destinations: const [
                  FuncBottomNavDestination(icon: AppIcons.home, label: '推荐'),
                ],
                selectedIndex: 0,
                form: FormFactor.pc,
                expanded: false,
                canToggle: true,
                onToggle: () {},
                onSelected: (_) {},
                onBookmarks: () {},
                onDownloads: () {},
              ),
            ),
          ),
        );
        for (final icon in const [AppIcons.heart, AppIcons.downloading]) {
          expect(find.byIcon(icon), findsOneWidget);
        }
        expect(find.byIcon(AppIcons.sidebarExpand), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'KeyboardBack handles Ctrl/Cmd settings, destination digits, rail toggle, and iOS Cmd',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          for (final path in const [
            '/recommended',
            '/ranking',
            '/new',
            '/search',
            '/settings',
            '/settings/all',
          ])
            GoRoute(path: path, builder: (_, _) => Text(path)),
        ],
      );
      addTearDown(router.dispose);
      var railToggles = 0;

      Future<void> pumpHost(TargetPlatform platform) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          localizedRouterApp(
            router,
            builder: (_, child) => KeyboardBack(
              router: router,
              onToggleRail: () => railToggles++,
              child: child!,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> chord(LogicalKeyboardKey mod, LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(mod);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(mod);
        await tester.pumpAndSettle();
      }

      try {
        await pumpHost(TargetPlatform.windows);
        for (final (key, path) in const [
          (LogicalKeyboardKey.comma, '/settings/all'),
          (LogicalKeyboardKey.digit2, '/ranking'),
        ]) {
          await chord(LogicalKeyboardKey.controlLeft, key);
          expect(router.routeInformationProvider.value.uri.path, path);
        }
        await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyB);
        expect(railToggles, 1);

        await pumpHost(TargetPlatform.iOS);
        await chord(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.digit1);
        expect(router.routeInformationProvider.value.uri.path, '/recommended');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'RecommendedHomePage matches novel and user initial loading skeletons',
    (tester) async {
      final pending = Completer<http.Response>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete(http.Response('{}', 500));
        }
      });
      final container = await signedInApiContainer(
        MockClient((_) => pending.future),
        overrides: [
          feedSnapshotStoreProvider.overrideWithValue(
            MemoryFeedSnapshotStore(),
          ),
        ],
      );
      addTearDown(container.dispose);

      for (final (type, skeleton) in [
        (RecommendedContentType.novel, NovelListSkeleton),
        (RecommendedContentType.user, UserListSkeleton),
      ]) {
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: RecommendedHomePage(initialType: type),
          ),
        );
        await tester.pump();
        expect(find.byType(skeleton), findsOneWidget);
      }
      pending.complete(
        jsonResponse({
          'novels': <Object?>[],
          'user_previews': <Object?>[],
          'next_url': null,
        }),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'DesktopCommandBar compacts to 40dp toolbar without duplicate branding when usesSystemTitleBar is true',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const SizedBox.shrink(),
            ),
            GoRoute(
              path: '/welcome',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        );
        addTearDown(router.dispose);
        List<DesktopTitleBarRegion> lastRegions = const [];
        double? lastHeight;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [...await signedInAccountOverrides()],
            child: localizedRouterApp(
              router,
              builder: (ctx, child) => DesktopChromeMetrics(
                usesSystemTitleBar: true,
                hostMetrics: const DesktopWindowPlatformMetrics(
                  isWayland: true,
                  usesSystemTitleBar: true,
                ),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
        );
        await tester.pumpAndSettle();

        final bar = find.byKey(const Key('desktop-command-bar'));
        expect(tester.getSize(bar).height, kDesktopCompactCommandBarHeight);
        expect(lastHeight, 0.0);
        expect(lastRegions, isEmpty);
        expect(find.text('Parfait'), findsNothing);
        expect(
          find.byKey(const Key('desktop-command-search-pill')),
          findsOneWidget,
        );

        router.go('/welcome');
        await tester.pumpAndSettle();
        expect(bar, findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
