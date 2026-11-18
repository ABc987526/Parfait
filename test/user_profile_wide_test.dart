import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/window/desktop_command_bar.dart';
import 'package:parfait/features/profile/profile_skeleton.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/profile_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

/// The profile header on a wide window, away from the phone-sized cases in
/// user_profile_test.dart (which also keeps that file under the size limit).
void main() {
  testWidgets('a large window keeps the name and its buttons together', (
    tester,
  ) async {
    setViewSize(tester, const Size(1920, 1080));
    final container = await makeProfileWorld(
      users: UserApi(
        works: [
          for (var id = 1; id <= 6; id++)
            illustJson(id, width: 300, height: 400),
        ],
        detail: sampleUser(42).copyWith(totalIllusts: 6, hasDetail: true),
      ),
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: const UserPage(userId: 42),
      ),
    );
    await tester.pumpAndSettle();

    // The identity block stays one content width instead of stretching the
    // name and the buttons to the window's two edges (B3).
    expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
    final name = tester.getRect(
      find.byKey(const ValueKey('profile-expanded-name')),
    );
    final share = tester.getRect(find.byIcon(Icons.share_outlined).first);
    final follow = tester.getRect(find.byType(FollowSwitchButton));
    expect(follow.left, name.left);
    expect(follow.left, lessThan(share.left));
    expect(
      follow.top - name.bottom,
      allOf(greaterThanOrEqualTo(0), lessThan(80)),
    );
    expect(
      share.right - name.left,
      lessThanOrEqualTo(ContentWidths.management),
    );
  });

  testWidgets('profile wide split activates only at >= 840x480', (
    tester,
  ) async {
    setViewSize(tester, const Size(1024, 768));
    final container = await makeProfileWorld(
      users: UserApi(
        works: [
          for (var id = 1; id <= 6; id++)
            illustJson(id, width: 300, height: 400),
        ],
        detail: sampleUser(42).copyWith(totalIllusts: 6, hasDetail: true),
      ),
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: const UserPage(userId: 42),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsNothing);

    setViewSize(tester, const Size(750, 900));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-wide-split')), findsNothing);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsOneWidget);

    setViewSize(tester, const Size(900, 440));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-wide-split')), findsNothing);
    expect(find.byKey(const ValueKey('profile-nested-scroll')), findsOneWidget);
  });

  testWidgets(
    'wide profile skeleton avoids duplicate back button and empty works hide total',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final users = UserApi(
        detail: sampleUser(42).copyWith(totalIllusts: 120, hasDetail: true),
        works: const [],
      )..detailGate = gate;
      final container = await makeProfileWorld(users: users);
      await tester.pumpWidget(
        DesktopCommandBarScope(
          active: true,
          child: localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ProfileSkeleton), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-wide-split')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(FeedEmpty), findsOneWidget);
      expect(find.textContaining('共 '), findsNothing);
    },
  );
}
