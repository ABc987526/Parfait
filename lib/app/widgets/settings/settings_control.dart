import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../../haptics/app_haptics.dart';
import '../../theme/forui_theme_bridge.dart';
import '../../theme/func_semantic_tokens.dart';
import 'settings_anchor.dart';

/// Settings switch row backed by [FSwitch]. Owns the toggle haptic: only a
/// user flip is felt, never an external value change.
class SettingsControl extends StatelessWidget {
  const SettingsControl({
    super.key,
    this.title,
    this.setting,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.locked = false,
    this.lockedIcon,
  });

  /// The title; defaults to the title of [setting].
  final Widget? title;

  /// The catalog entry this row is the place of (settings search).
  final SettingsEntry? setting;
  final bool value;

  /// Null disables the row (the switch greys out and ignores taps).
  final ValueChanged<bool>? onChanged;
  final Widget? subtitle;

  /// A leading icon.
  final Widget? secondary;

  /// Null keeps the list-tile default; a row inside an already padded form
  /// passes [EdgeInsets.zero] so its text lines up with the form.
  final EdgeInsetsGeometry? contentPadding;

  /// Marks a disabled-selected row as intentionally locked (tinted active track
  /// plus [lockedIcon] on the thumb, preserving `onChanged == null`).
  final bool locked;

  /// Optional 12dp glyph overlaid on the active thumb when [locked] is true.
  final IconData? lockedIcon;

  void _handleToggle(bool next, ValueChanged<bool> onChanged) {
    next ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final showLocked = locked && value && onChanged == null;
    final scheme = Theme.of(context).colorScheme;
    final switchStyle = showLocked
        ? FSwitchStyleDelta.delta(
            trackColor: FVariants.all(
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.40),
                scheme.surfaceContainerHighest,
              ),
            ),
            thumbColor: FVariants.all(scheme.onPrimary),
          )
        : const FSwitchStyleDelta.context();

    Widget control = FSwitch(
      value: value,
      enabled: onChanged != null,
      style: switchStyle,
      onChange: onChanged == null
          ? null
          : (next) => _handleToggle(next, onChanged),
    );
    if (showLocked && lockedIcon != null) {
      final iconColor =
          scheme.brightness == Brightness.dark &&
              scheme.onPrimary.computeLuminance() > 0.5
          ? scheme.primaryContainer
          : scheme.primary;
      control = Stack(
        alignment: AlignmentDirectional.centerEnd,
        children: [
          control,
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: FuncSpacing.sm),
              child: SizedBox.square(
                dimension: 20,
                child: Center(
                  child: Icon(lockedIcon, size: 12, color: iconColor),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: ForuiThemeHost.ensure(
          context,
          anchorSettingsRow(
            setting,
            ListTile(
              enabled: onChanged != null,
              leading: secondary,
              title: title ?? Text(settingsRowTitle(context, null, setting)),
              subtitle: subtitle,
              contentPadding: contentPadding,
              trailing: ExcludeSemantics(child: ExcludeFocus(child: control)),
              onTap: onChanged == null
                  ? null
                  : () => _handleToggle(!value, onChanged),
            ),
          ),
        ),
      ),
    );
  }
}
