import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/feed_selection.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/settings/shared_preferences.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart'
    show beginImageViewerSession;
import 'package:parfait/features/search/search_filter_labels.dart';

import 'review_support.dart';

class _SpreadNovelSettingsStore extends NovelReaderSettingsStore {
  _SpreadNovelSettingsStore(super.preferences);

  NovelReaderSettings _current = const NovelReaderSettings(
    pageTurn: NovelPageTurn.pages,
    spreadMode: NovelSpreadMode.auto,
  );

  @override
  Future<NovelReaderSettings> load() async => _current;

  @override
  Future<void> save(NovelReaderSettings settings) async {
    _current = settings;
  }
}

/// Multi-platform acceptance scenes covering all 5 OS shells (Android, iOS,
/// Windows, macOS, Linux), foldable postures (`book` and `tabletop`), adaptive
/// overlay container choices, novel spreads, wide profiles/dashboards, and real
/// isolate + chunked HTTP image streaming.
void main() {
  testShot('mp/home-recommended', location: '/recommended');

  testShot(
    'mp/illust-detail',
    location: '/recommended',
    before: (tester, router) async {
      unawaited(router.push('/recommended/illust/1000'));
      await tester.pump();
    },
  );

  testShot(
    'mp/adaptive-dialog',
    location: '/recommended',
    before: (tester, router) async {
      final target = find.byType(IllustCard).first;
      final modality = InputModalityScope.maybeOf(tester.element(target));
      if (modality == InputModality.pointer) {
        final pos = tester.getRect(target).topCenter + const Offset(0, 32);
        final gesture = await tester.startGesture(
          pos,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
      } else {
        await tester.longPress(find.byType(PixivImage).at(1));
      }
    },
  );

  testShot(
    'mp/adaptive-sidesheet',
    location: '/search/results?q=landscape%20cat&type=illust',
    before: (tester, router) async {
      await tester.tap(find.byType(SearchFilterButton).last);
    },
  );

  testShot(
    'mp/novel-spread',
    location: '/recommended/novel/2000',
    setup: ReviewSetup(
      overrides: [
        novelReaderSettingsStoreProvider.overrideWith(
          (ref) =>
              _SpreadNovelSettingsStore(ref.watch(sharedPreferencesProvider)),
        ),
      ],
    ),
  );

  testShot('mp/profile-user', location: '/recommended/user/99');

  testShot(
    'mp/me-dashboard',
    location: '/settings',
    before: (tester, router) async {
      final expandRail = find.byTooltip('展开侧栏');
      if (expandRail.evaluate().isNotEmpty) {
        await tester.tap(expandRail);
      }
    },
  );

  testShot(
    'mp/progressive-detail',
    location: '/recommended/illust/1000',
    setup: const ReviewSetup(
      realWorkerIsolate: true,
      imageChunkSize: 16384,
      imageChunkDelay: Duration(milliseconds: 2),
    ),
  );

  testShot(
    'mp/desktop-command-filter',
    location: '/recommended',
    before: (tester, router) async {
      final filter = find.byKey(const Key('desktop-command-filter'));
      if (filter.evaluate().isNotEmpty) {
        await tester.tap(filter);
      }
    },
  );

  testShot(
    'mp/viewer-info-panel',
    location: '/recommended/illust/1000/viewer/0',
    before: (tester, router) async {
      beginImageViewerSession();
      final info = find.byIcon(Icons.info_outline);
      if (info.evaluate().isNotEmpty) {
        await tester.tap(info.first);
      }
    },
  );

  testShot(
    'mp/feed-batch-select',
    location: '/recommended',
    before: (tester, router) async {
      final card = find.byType(IllustCard);
      if (card.evaluate().isNotEmpty) {
        final scope = FeedSelectionScope.maybeOf(tester.element(card.first));
        if (scope != null && scope.enabled) {
          scope.toggle(1000);
          scope.selectRangeTo(1002);
        }
      }
    },
  );
}
