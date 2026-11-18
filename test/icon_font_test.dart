import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iconFont asset registration', () {
    test('assets/icon.ttf is bundled and non-empty', () async {
      final data = await rootBundle.load('assets/icon.ttf');
      expect(data.lengthInBytes, greaterThan(0));
    });

    test(
      'pubspec registers the iconFont family pointing at assets/icon.ttf',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec.contains('family: iconFont'), isTrue);
        expect(
          pubspec.contains('asset: assets/icon.ttf'),
          isTrue,
          reason: 'pubspec.yaml must declare assets/icon.ttf under fonts',
        );
        final dartIcons = File(
          'lib/app/icons/app_icons.dart',
        ).readAsStringSync();
        final svgCount = Directory('tool/icons/svg')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.svg'))
            .length;
        expect(
          RegExp(r'0xe9[0-9a-f]{2}').allMatches(dartIcons).length,
          svgCount,
          reason: 'AppIcons codepoints must stay in sync with tool/icons/svg/',
        );
      },
    );
  });
}
