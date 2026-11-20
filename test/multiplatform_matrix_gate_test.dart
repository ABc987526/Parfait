import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/layout/window_layout_spec.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/route_extras.dart';
import 'package:parfait/app/widgets/card_actions/card_action_sheet.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/detail/widgets/detail_image_pager.dart';

import 'helpers/card_world.dart';
import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

Future<void> _drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> _unmountTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
    'golden scenario: compact_phone iOS uses bottom nav, frosted card menu, and single-column canvas dismiss',
    (tester) async {
      setViewSize(tester, const Size(390, 844));
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(illustJson(42));
      container.read(illustStoreProvider).mergeAll([entity]);
      final router = pixivRouter('/recommended');
      try {
        await tester.pumpWidget(
          localizedRouterApp(router, container: container),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(FuncBottomNav), findsOneWidget);
        expect(find.byType(ShellRail), findsNothing);

        final navCtx = tester.element(find.byType(FuncBottomNav));
        expect(
          WindowLayoutSpec.of(navCtx).widthClass,
          WindowWidthClass.compact,
        );

        unawaited(showCardActionSheet(navCtx, entity));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          find.byKey(const Key('ios-card-context-preview')),
          findsOneWidget,
        );
        expect(find.byType(ListTile), findsNothing);
        await tester.tapAt(const Offset(4, 300));
        await tester.pumpAndSettle();

        unawaited(
          router.push(
            '/recommended/illust/42',
            extra: IllustRouteExtra(
              entity: entity,
              heroImageUrl: entity.squareUrlAt(0),
            ),
          ),
        );
        await _drain(tester);
        expect(find.byType(IllustDetailPage), findsOneWidget);
        expect(find.byType(DetailImagePager), findsNothing);
        expect(
          find.byKey(const ValueKey('func-shared-canvas-clip')),
          findsOneWidget,
        );

        final drag = await tester.startGesture(const Offset(195, 240));
        await drag.moveBy(const Offset(0, 28));
        await drag.moveBy(const Offset(0, 140));
        await tester.pump();
        expect(
          tester
              .getRect(find.byKey(const ValueKey('func-shared-canvas-clip')))
              .width,
          lessThan(390.0),
        );
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byType(IllustDetailPage), findsNothing);
        expect(router.state.uri.path, '/recommended');
      } finally {
        await _unmountTree(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'golden scenario: foldable_book separates artwork pager and inspector across vertical hinge',
    (tester) async {
      final (container, _, _) = await makeWorld();
      setViewSize(tester, const Size(760, 840));
      tester.view.displayFeatures = const [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(374, 0, 12, 840),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(tester.view.resetDisplayFeatures);

      try {
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: const IllustDetailPage(illustId: 42),
          ),
        );
        await _drain(tester);

        final spec = WindowLayoutSpec.of(
          tester.element(find.byType(IllustDetailPage)),
        );
        expect(spec.posture, FoldPosture.book);
        final pager = tester.getRect(find.byType(DetailImagePager));
        final inspectorBar = tester.getRect(
          find.byKey(const ValueKey('detail-inspector-action-bar')),
        );
        expect(pager.right, lessThanOrEqualTo(374));
        expect(inspectorBar.left, greaterThanOrEqualTo(386));
        expect(find.byType(DetailActionBar), findsNothing);
      } finally {
        await _unmountTree(tester);
      }
    },
  );

  testWidgets(
    'golden scenario: foldable_tabletop separates upper media and lower controls across horizontal hinge',
    (tester) async {
      final (container, _, _) = await makeWorld();
      setViewSize(tester, const Size(840, 760));
      tester.view.displayFeatures = const [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(0, 374, 840, 12),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(tester.view.resetDisplayFeatures);

      try {
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: const IllustDetailPage(illustId: 42),
          ),
        );
        await _drain(tester);

        final spec = WindowLayoutSpec.of(
          tester.element(find.byType(IllustDetailPage)),
        );
        expect(spec.posture, FoldPosture.tabletop);
        final pager = tester.getRect(find.byType(DetailImagePager));
        final inspectorBar = tester.getRect(
          find.byKey(const ValueKey('detail-inspector-action-bar')),
        );
        expect(pager.bottom, lessThanOrEqualTo(374));
        expect(inspectorBar.top, greaterThanOrEqualTo(386));
      } finally {
        await _unmountTree(tester);
      }
    },
  );

  testWidgets(
    'golden scenario: tablet_expanded iOS shows navigation rail and two-pane detail layout',
    (tester) async {
      setViewSize(tester, const Size(1194, 834));
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(illustJson(42));
      container.read(illustStoreProvider).mergeAll([entity]);
      final router = pixivRouter('/recommended');
      try {
        await tester.pumpWidget(
          localizedRouterApp(router, container: container),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(ShellRail), findsOneWidget);
        expect(find.byType(FuncBottomNav), findsNothing);

        unawaited(
          router.push(
            '/recommended/illust/42',
            extra: IllustRouteExtra(entity: entity),
          ),
        );
        await _drain(tester);
        final pager = tester.getRect(find.byType(DetailImagePager));
        final inspector = tester.getRect(
          find.byKey(const ValueKey('detail-inspector-action-bar')),
        );
        expect(inspector.left, greaterThanOrEqualTo(pager.right));
      } finally {
        await _unmountTree(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'golden scenario: desktop_multimonitor_pointer handles 1x<->2x DPR transitions and pointer right-click menu',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      addTearDown(tester.view.resetDevicePixelRatio);
      final (cardContainer, _, _) = await makeCardWorld();
      final router = pixivRouter('/recommended');
      try {
        await tester.pumpWidget(
          localizedRouterApp(router, container: cardContainer),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(ShellRail), findsOneWidget);
        expect(find.byType(FuncBottomNav), findsNothing);
        expect(
          WindowLayoutSpec.of(
            tester.element(find.byType(ShellRail)),
          ).inputModality,
          InputModality.pointer,
        );

        // Simulate dragging the window onto a 2x HiDPI monitor and back to 1x.
        tester.view
          ..devicePixelRatio = 2.0
          ..physicalSize = const Size(3840, 2160);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        expect(find.byType(ShellRail), findsOneWidget);

        tester.view
          ..devicePixelRatio = 1.0
          ..physicalSize = const Size(1280, 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);

        final card = find.byType(IllustCard);
        if (card.evaluate().isNotEmpty) {
          final rightClick = await tester.startGesture(
            tester.getCenter(card.first),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await rightClick.up();
          await tester.pump();
          expect(find.byKey(const Key('ios-card-context-menu')), findsNothing);
        }
      } finally {
        await _unmountTree(tester);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'reduced motion gate disables scale and displacement on shared-element dismiss and context menu',
    (tester) async {
      setViewSize(tester, const Size(390, 844));
      final (container, _, _) = await makeCardWorld();
      late BuildContext pushContext;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: localizedApp(
            container: container,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 180,
                  height: 260,
                  child: Builder(
                    builder: (context) {
                      pushContext = context;
                      return IllustCard(entity: parseIllust(illustJson(11)));
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.longPress(find.byType(IllustCard));
      await tester.pump();
      final previewTransform = tester.widget<Transform>(
        find
            .ancestor(
              of: find.byKey(const Key('ios-card-context-preview')),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(previewTransform.transform, Matrix4.identity());
      await tester.tapAt(const Offset(4, 300));
      await tester.pumpAndSettle();

      unawaited(
        Navigator.of(pushContext).push<void>(
          FuncPage<void>(
                sharedElement: true,
                child: const Scaffold(
                  body: Center(child: Text('reduced-page')),
                ),
              ).createRoute(pushContext)
              as PageRoute<void>,
        ),
      );
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(const Offset(195, 220));
      await drag.moveBy(const Offset(0, 28));
      await drag.moveBy(const Offset(0, 140));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('func-shared-canvas-clip'))),
        const Rect.fromLTWH(0, 0, 390, 844),
      );
      await drag.up();
      await tester.pumpAndSettle();
      expect(find.text('reduced-page'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
