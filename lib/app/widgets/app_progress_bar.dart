import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/forui_theme_bridge.dart';

/// Shared linear progress bar backed by Forui's [FDeterminateProgress] when
/// [value] is provided and [FProgress] when indeterminate.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    this.value,
    this.minHeight,
    this.semanticsLabel,
  });

  final double? value;
  final double? minHeight;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final height = minHeight;
    final current = value;
    final bar = current != null
        ? FDeterminateProgress(
            value: current.clamp(0.0, 1.0),
            semanticsLabel: semanticsLabel,
            style: height == null
                ? const FDeterminateProgressStyleDelta.context()
                : FDeterminateProgressStyleDelta.delta(
                    constraints: BoxConstraints.tightFor(height: height),
                  ),
          )
        : FProgress(
            semanticsLabel: semanticsLabel,
            style: height == null
                ? const FProgressStyleDelta.context()
                : FProgressStyleDelta.delta(
                    constraints: BoxConstraints.tightFor(height: height),
                  ),
          );
    return ForuiThemeHost.ensure(context, bar);
  }
}
