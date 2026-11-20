import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// Shared minimalist progress spinner using the hairline sakura track and
/// rounded stroke cap.
class AppSpinner extends StatelessWidget {
  const AppSpinner({
    super.key,
    this.size = 24.0,
    this.strokeWidth = 2.4,
    this.color,
    this.trackColor,
    this.value,
    this.semanticsLabel,
  });

  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? trackColor;
  final double? value;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hairline =
        theme.extension<FuncSemanticTokens>()?.brandHairline ??
        theme.progressIndicatorTheme.circularTrackColor ??
        colors.outlineVariant;
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        value: value,
        strokeWidth: strokeWidth,
        strokeCap: StrokeCap.round,
        color: color ?? colors.primary,
        backgroundColor: trackColor ?? hairline,
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}
