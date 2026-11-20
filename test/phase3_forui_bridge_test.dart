import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/theme/forui_theme_bridge.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:parfait/app/widgets/app_progress_bar.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/app/widgets/settings/settings_control.dart';

import 'helpers/localized_app.dart';

void main() {
  test(
    'foruiThemeFrom bridges colors, hairlines, haptics, and keeps platform font',
    () {
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF006D77),
        brightness: Brightness.light,
      );
      for (final (brightness, scheme) in [
        (Brightness.light, null),
        (Brightness.dark, null),
        (Brightness.light, dynamicScheme),
      ]) {
        final material = replicaTheme(brightness, systemColors: scheme);
        final fTheme = foruiThemeFrom(material, touch: true);
        final tokens = material.extension<FuncSemanticTokens>()!;

        expect(fTheme.colors.brightness, brightness);
        expect(fTheme.colors.primary, material.colorScheme.primary);
        expect(fTheme.colors.border, tokens.brandHairline);
        expect(fTheme.hapticFeedback, const FHapticFeedback.none());

        final expectedFamily = material.textTheme.bodyMedium?.fontFamily;
        for (final face in [
          fTheme.typography.display,
          fTheme.typography.body,
        ]) {
          for (final style in [
            face.xs3,
            face.xs2,
            face.xs,
            face.sm,
            face.md,
            face.lg,
            face.xl,
            face.xl2,
            face.xl3,
            face.xl4,
            face.xl5,
            face.xl6,
            face.xl7,
            face.xl8,
          ]) {
            expect(style.fontFamily, expectedFamily);
            expect(style.fontFamily, isNot('packages/forui/Inter'));
          }
        }
      }
    },
  );

  testWidgets(
    'ForuiThemeHost forwards MotionScope reduce to FAccessibilityMotion.disabled',
    (tester) async {
      FAccessibilityMotion? captured;
      Widget probe(bool reduce) => localizedApp(
        body: MotionScope(
          reduce: reduce,
          child: ForuiThemeHost(
            child: Builder(
              builder: (context) {
                captured = FAccessibilityScope.motionOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await tester.pumpWidget(probe(true));
      expect(captured, FAccessibilityMotion.disabled);

      await tester.pumpWidget(probe(false));
      expect(captured, FAccessibilityMotion.all);
    },
  );

  testWidgets(
    'SettingsControl locked mode renders disabled active FSwitch with lock icon',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: const SettingsControl(
            title: Text('Home'),
            value: true,
            onChanged: null,
            locked: true,
            lockedIcon: AppIcons.lock,
          ),
        ),
      );

      final sw = tester.widget<FSwitch>(find.byType(FSwitch));
      expect(sw.value, isTrue);
      expect(sw.enabled, isFalse);
      expect(find.byIcon(AppIcons.lock), findsOneWidget);
    },
  );

  testWidgets(
    'AppSlider bridges FSlider with ExcludeFocus and preserves scrubber Slider',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: Column(
            children: [
              AppSlider(
                value: 2,
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: (_) {},
              ),
              AppSlider(value: 0.5, onChanged: (_) {}),
              AppSlider.scrubber(value: 0.5, onChanged: (_) {}),
            ],
          ),
        ),
      );

      expect(find.byType(FSlider), findsNWidgets(2));
      expect(
        find.ancestor(
          of: find.byType(FSlider),
          matching: find.byWidgetPredicate(
            (w) => w is ExcludeFocus && w.excluding,
          ),
        ),
        findsNWidgets(2),
      );
      expect(find.byType(Slider), findsOneWidget);
    },
  );

  testWidgets(
    'AppProgressBar renders FDeterminateProgress when bounded and FProgress when null',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: const Column(
            children: [AppProgressBar(value: 1.5), AppProgressBar()],
          ),
        ),
      );

      final determinate = tester.widget<FDeterminateProgress>(
        find.byType(FDeterminateProgress),
      );
      expect(determinate.value, 1.0);
      expect(find.byType(FProgress), findsOneWidget);
    },
  );

  testWidgets(
    'AppDatePickerDialog clamps out-of-range today and returns a local DateTime',
    (tester) async {
      DateTime? picked;
      late String okLabel;
      await tester.pumpWidget(
        localizedApp(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                okLabel = MaterialLocalizations.of(context).okButtonLabel;
                picked = await showAppDatePicker(
                  context: context,
                  firstDate: DateTime(2007, 9, 13),
                  lastDate: DateTime(2007, 9, 20),
                  initialDate: DateTime(2007, 9, 18),
                );
              },
              child: const Text('Pick'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.byType(FCalendar), findsOneWidget);

      await tester.tap(find.text(okLabel));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2007, 9, 18));
      expect(picked!.isUtc, isFalse);
    },
  );

  testWidgets(
    'AppAlertDialog mounts FDialog with inner Material for TextField',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: AppAlertDialog(
            title: const Text('Title'),
            content: const TextField(),
            actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
          ),
        ),
      );

      expect(find.byType(FDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(FDialog),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
    },
  );
}
