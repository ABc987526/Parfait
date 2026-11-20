import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/clipboard.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/share/share_service.dart';

import 'helpers/prompt_host.dart';
import 'helpers/recording_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharePayload', () {
    test('each payload shares its title, author and canonical URL', () {
      for (final (payload, url, text) in [
        (
          SharePayload.illust(id: 1234, title: 'A piece', author: 'an artist'),
          'https://www.pixiv.net/artworks/1234',
          'A piece | an artist #Pixiv https://www.pixiv.net/artworks/1234',
        ),
        (
          SharePayload.novel(id: 77, title: 'A story', author: 'a writer'),
          'https://www.pixiv.net/novel/show.php?id=77',
          'A story | a writer #Pixiv https://www.pixiv.net/novel/show.php?id=77',
        ),
        (
          SharePayload.user(id: 42, name: 'tester'),
          'https://www.pixiv.net/users/42',
          'tester | tester #Pixiv https://www.pixiv.net/users/42',
        ),
      ]) {
        expect((payload.url, payload.text), (url, text));
      }
    });
  });

  group('SystemShareService', () {
    test('missing platform support falls back to the clipboard', () async {
      final payload = SharePayload.user(id: 42, name: 'tester');
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      // share_plus has no implementation in the test environment, so the
      // plugin throws and the service must degrade to a clipboard copy
      // instead of surfacing an error.
      final outcome = await const SystemShareService().share(payload);
      expect(outcome, ShareOutcome.copiedToClipboard);
      expect(copied, payload.text);
    });
  });

  group('copyToClipboard', () {
    List<String> mockClipboard({bool fail = false}) {
      final written = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (fail) throw PlatformException(code: 'clipboard_unavailable');
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      return written;
    }

    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          builder: promptHostBuilder,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return context;
    }

    testWidgets('copies, confirms with the success haptic and a toast', (
      tester,
    ) async {
      final haptics = recordHaptics();
      final written = mockClipboard();
      final context = await pumpHost(tester);

      await copyToClipboard(context, 'pixiv.net', message: 'Copied');
      await tester.pump();

      expect(written, ['pixiv.net']);
      expect(haptics.roles, [HapticRole.success]);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('a failed write claims nothing', (tester) async {
      final haptics = recordHaptics();
      mockClipboard(fail: true);
      final context = await pumpHost(tester);

      await expectLater(
        copyToClipboard(context, 'pixiv.net', message: 'Copied'),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump();

      expect(haptics.played, isEmpty);
      expect(find.text('Copied'), findsNothing);
    });
  });
}
