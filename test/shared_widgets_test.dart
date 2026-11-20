import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_spinner.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/master_detail_workspace.dart';
import 'package:parfait/app/widgets/scroll_edge_fade.dart';
import 'package:parfait/app/widgets/settings/settings_anchor.dart';
import 'package:parfait/app/widgets/settings/settings_group.dart';
import 'package:parfait/app/widgets/skeleton/func_skeleton.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

void main() {
  group('retry on network restore (HCI 9)', () {
    test('only the way back from no network counts as a restore', () {
      final container = ProviderContainer.test();
      final signal = container.read(networkRestoreSignalProvider.notifier);
      int restores() => container.read(networkRestoreSignalProvider);

      signal.observe('wifi');
      signal.observe('mobile');
      expect(restores(), 0, reason: 'switching live networks');
      signal.observe(offlineNetworkIdentity);
      signal.observe('vpn+wifi');
      expect(restores(), 1);
      signal.observe('wifi');
      expect(restores(), 1);
    });

    Future<ProviderContainer> pumpError(
      WidgetTester tester,
      Widget state,
    ) async {
      final container = ProviderContainer.test();
      await tester.pumpWidget(
        localizedApp(
          container: container,
          locale: null,
          theme: replicaTheme(Brightness.light),
          body: state,
        ),
      );
      return container;
    }

    void restore(ProviderContainer container) {
      container.read(networkRestoreSignalProvider.notifier)
        ..observe(offlineNetworkIdentity)
        ..observe('wifi');
    }

    testWidgets('a connection failure retries once per restore', (
      tester,
    ) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedError(
          title: 'Failed',
          error: const ApiNetworkError('socket closed'),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 1);
      container.read(networkRestoreSignalProvider.notifier).observe('mobile');
      await tester.pump();
      expect(retries, 1, reason: 'a network switch is not a restore');
      restore(container);
      await tester.pump();
      expect(retries, 2);
    });

    testWidgets('a failed page further down retries too', (tester) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedTail(
          feed: const PagedFeedState(
            initialPhase: FeedPhase.idle,
            loadMorePhase: FeedPhase.error,
            loadMoreError: ApiTimeout(),
          ),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('a failure the network does not explain stays put', (
      tester,
    ) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedError(
          title: 'Failed',
          error: const ApiHttpError(404),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 0);
    });
  });

  testWidgets('a section retries twice on its own, then waits for the user', (
    tester,
  ) async {
    var retries = 0;
    Future<void> show({required bool failed, Object? error}) =>
        tester.pumpWidget(
          AutoRetry(
            failed: failed,
            error: error,
            onRetry: () => retries++,
            child: const SizedBox(),
          ),
        );
    const rateLimited = ApiRateLimited(Duration(seconds: 5));
    final [first, second] = AutoRetry.delays;

    await show(failed: true, error: const ApiTimeout());
    await tester.pump(first);
    expect(retries, 1);
    await show(failed: false);
    // A rate limit waits at least as long as the server asked.
    await show(failed: true, error: rateLimited);
    await tester.pump(second);
    expect(retries, 1);
    await tester.pump(rateLimited.retryAfter! - second);
    expect(retries, 2);
    await show(failed: false);
    await show(failed: true, error: const ApiTimeout());
    await tester.pump(const Duration(minutes: 1));
    expect(retries, 2);
  });

  testWidgets('a paused feed tail offers continue, which pages on', (
    tester,
  ) async {
    var continued = 0;
    await tester.pumpWidget(
      localizedApp(
        locale: const Locale('en'),
        theme: replicaTheme(Brightness.light),
        body: FeedTail(
          feed: const PagedFeedState(
            initialPhase: FeedPhase.idle,
            loadMorePaused: true,
          ),
          onRetry: () => continued++,
          retryLabel: 'Retry',
        ),
      ),
    );
    final button = find.byKey(const Key('feed-continue-loading'));
    expect(button, findsOneWidget);
    expect(find.text('Continue loading'), findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    expect(continued, 1);
  });

  testWidgets('a text bone is as tall as a line of its style at every '
      'text scale', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    const style = TextStyle(fontSize: 14, height: 1.4);
    for (final scale in [1.0, 2.0, 1.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SkeletonBone.text(width: 80, style: style),
              Text('x', style: style),
            ],
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SkeletonBone)).height,
        tester.getSize(find.text('x')).height,
      );
    }
  });

  testWidgets(
    'an empty state stands as high under a bar with tabs as without',
    (tester) async {
      Future<double> centerUnder(PreferredSizeWidget? tabs) async {
        await tester.pumpWidget(
          localizedApp(
            theme: replicaTheme(Brightness.light),
            home: DefaultTabController(
              length: 2,
              child: Scaffold(
                appBar: AppTopBar(title: const Text('page'), bottom: tabs),
                body: const FeedEmpty(title: 'nothing here'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getCenter(find.text('nothing here')).dy;
      }

      final plain = await centerUnder(null);
      final tabbed = await centerUnder(const AppTabBar(labels: ['a', 'b']));
      expect(tabbed, moreOrLessEquals(plain));
    },
  );

  testWidgets('a capped top bar follows the content column', (tester) async {
    setViewSize(tester, const Size(1400, 800));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        home: Scaffold(
          appBar: AppTopBar(
            contentWidth: ContentWidths.settings,
            leading: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.arrow_back),
            ),
            title: const Text('设置'),
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 600-wide column in a 1400 window: 400 free on each side.
    const inset = 400.0;
    final back = tester.getRect(find.byIcon(Icons.arrow_back));
    final action = tester.getRect(find.byIcon(Icons.more_vert));
    final title = tester.getRect(find.text('设置'));
    expect(back.left, greaterThanOrEqualTo(inset));
    expect(back.center.dx, lessThan(inset + kToolbarHeight));
    expect(action.right, lessThanOrEqualTo(1400 - inset));
    expect(action.right, greaterThan(1400 - inset - kToolbarHeight));
    // The title starts just past the back control, inside the column.
    expect(
      title.left,
      closeTo(inset + kToolbarHeight + NavigationToolbar.kMiddleSpacing, .5),
    );
    // Only the controls move in: the bar's surface still spans the page.
    expect(tester.getRect(find.byType(AppBar)).width, 1400);
  });

  testWidgets('an empty state scrolls only when the window cannot hold it', (
    tester,
  ) async {
    Widget empty() => FeedEmpty(
      icon: Icons.search,
      title: 'nothing here',
      detail: 'try another search',
      retryLabel: 'refresh',
      onRefresh: () async {},
      actionLabel: 'edit',
      onAction: () {},
    );

    // A turned phone's short window under a bar with a search row and a
    // filter row: the buttons are reached by scrolling, nothing overflows.
    setViewSize(tester, const Size(568, 320));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        home: Scaffold(
          appBar: AppTopBar(
            title: const Text('page'),
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(96),
              child: SizedBox.shrink(),
            ),
          ),
          body: empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('edit'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('edit')).bottom, lessThanOrEqualTo(320));

    // Laid out at its own height in a page's scroll, it leaves the drag to
    // that scroll, which pulls down to refresh.
    final page = ScrollController();
    addTearDown(page.dispose);
    setViewSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        // The app's: a page's scroll and a status view's take any drag.
        scrollBehavior: const FuncScrollBehavior(),
        home: Scaffold(
          body: CustomScrollView(
            controller: page,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverFillRemaining(hasScrollBody: false, child: empty()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(
      tester.getCenter(find.text('nothing here')),
    );
    await drag.moveBy(const Offset(0, 40));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(page.offset, lessThan(0));
    final inner = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(FeedEmpty),
        matching: find.byType(Scrollable),
      ),
    );
    expect(inner.position.pixels, 0);
    await drag.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'AppTopBar keeps disabled IconButton and TextButton foreground alpha >= 0.45',
    (tester) async {
      setViewSize(tester, const Size(390, 800));
      for (final brightness in Brightness.values) {
        final theme = replicaTheme(brightness);
        final tokens = theme.extension<FuncSemanticTokens>()!;
        await tester.pumpWidget(
          localizedApp(
            theme: theme,
            home: Scaffold(
              appBar: AppTopBar(
                title: const Text('History'),
                actions: [
                  TextButton(onPressed: null, child: const Text('Manage')),
                  IconButton(
                    tooltip: 'Clear',
                    onPressed: null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.backgroundColor, isNull);
        expect(theme.appBarTheme.backgroundColor, tokens.canvas);
        final textColor = DefaultTextStyle.of(
          tester.element(find.text('Manage')),
        ).style.color!;
        final iconColor = IconTheme.of(
          tester.element(find.byIcon(Icons.delete_outline)),
        ).color!;
        expect(textColor.a, greaterThanOrEqualTo(0.45), reason: '$brightness');
        expect(iconColor.a, greaterThanOrEqualTo(0.45), reason: '$brightness');
      }
    },
  );

  testWidgets(
    'MasterDetailWorkspace wraps scrollable masterBody in vertical ScrollEdgeFade',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        localizedApp(
          theme: replicaTheme(Brightness.light),
          home: MasterDetailWorkspace(
            title: const Text('Settings'),
            masterBody: ListView.builder(
              itemCount: 30,
              itemBuilder: (_, index) =>
                  SizedBox(height: 56, child: Text('Section $index')),
            ),
            detail: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final fadeFinder = find.descendant(
        of: find.byType(MasterDetailWorkspace),
        matching: find.byType(ScrollEdgeFade),
      );
      expect(fadeFinder, findsOneWidget);
      expect(tester.widget<ScrollEdgeFade>(fadeFinder).axis, Axis.vertical);
      expect(tester.state<ScrollEdgeFadeState>(fadeFinder).fades, (
        false,
        true,
      ));
    },
  );

  testWidgets(
    'unified SettingsGroup card, FuncBottomNav hairline, SakuraRefreshIndicator, and AppSpinner',
    (tester) async {
      setViewSize(tester, const Size(390, 800));
      final theme = replicaTheme(Brightness.light);
      final tokens = theme.extension<FuncSemanticTokens>()!;
      final removals = RemovalController();
      addTearDown(removals.dispose);
      bool isHairline(Widget w) =>
          w is ColoredBox && w.color == tokens.brandHairline;

      await tester.pumpWidget(
        localizedApp(
          theme: theme,
          home: Scaffold(
            body: SettingsFocusScope(
              target: SettingsPageRef.theme.id,
              child: RemovalScope(
                controller: removals,
                child: ListView(
                  children: [
                    SettingsGroup(
                      setting: SettingsPageRef.theme,
                      children: const [
                        Removable(
                          id: 'a',
                          child: ListTile(title: Text('A')),
                        ),
                        Removable(
                          id: 'b',
                          child: ListTile(title: Text('B')),
                        ),
                      ],
                    ),
                    MediaQuery(
                      data: const MediaQueryData(disableAnimations: true),
                      child: SakuraRefreshIndicator(
                        progress: 0.6,
                        spinning: true,
                        color: theme.colorScheme.primary,
                        trackColor: tokens.brandHairline,
                      ),
                    ),
                    const AppSpinner(value: 0.5),
                  ],
                ),
              ),
            ),
            bottomNavigationBar: FuncBottomNav(
              destinations: const [
                FuncBottomNavDestination(icon: Icons.home, label: 'Home'),
                FuncBottomNavDestination(icon: Icons.person, label: 'Me'),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SettingsCard), findsOneWidget);
      Finder in_(Type p, Finder m) =>
          find.descendant(of: find.byType(p), matching: m);
      final card = tester.widget<Material>(
        in_(SettingsCard, find.byType(Material)).first,
      );
      expect(
        (card.shape! as RoundedRectangleBorder).side.color,
        tokens.brandHairline,
      );
      expect(in_(SettingsGroup, find.byType(SettingMarkOverlay)), findsOne);
      final divider = in_(SettingsGroup, find.byWidgetPredicate(isHairline));
      expect(divider, findsOneWidget);

      final exitFuture = removals.playExit(const ['b']);
      await tester.pumpAndSettle();
      await exitFuture;
      expect(divider, findsNothing);

      expect(find.byType(SakuraRefreshIndicator), findsOneWidget);
      final spinner = tester.widget<CircularProgressIndicator>(
        in_(AppSpinner, find.byType(CircularProgressIndicator)),
      );
      expect(spinner.backgroundColor, tokens.brandHairline);
      expect(spinner.strokeCap, StrokeCap.round);
      final navBox = tester.widget<DecoratedBox>(
        in_(FuncBottomNav, find.byType(DecoratedBox)).first,
      );
      expect(
        (navBox.decoration as BoxDecoration).border,
        Border(top: BorderSide(color: tokens.brandHairline)),
      );
    },
  );
}
