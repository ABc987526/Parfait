import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';
import 'settings_anchor.dart';

/// A row that opens another page or section; its chevron says so.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.selectedIcon,
    this.subtitle,
    this.selected = false,
    this.trailingBadge,
    this.trailingText,
    this.showChevron = true,
  });

  /// Top-level destination entry on the Me dashboard or Settings index.
  ///
  /// Uses a monochrome [icon] (switching to [selectedIcon] when [selected])
  /// without multi-hue category discs, matching desktop master-detail rails
  /// and unified gallery surfaces.
  const SettingsTile.topLevel({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.selectedIcon,
    this.subtitle,
    this.selected = false,
    this.trailingBadge,
    this.trailingText,
    this.showChevron = true,
  });

  /// Optional leading icon rendered monochrome at rest and accented when
  /// [selected].
  final IconData? icon;

  /// Optional alternate glyph shown when [selected] is true.
  final IconData? selectedIcon;

  /// The title; defaults to the title of [setting].
  final String? title;

  /// The catalog entry this row is the place of (settings search).
  final SettingsEntry? setting;
  final VoidCallback onTap;

  /// Optional summary row.
  final Widget? subtitle;

  /// Whether this row represents the active master-detail destination.
  final bool selected;

  /// Optional trailing badge (e.g. active task count) shown beside or in place
  /// of the chevron.
  final Widget? trailingBadge;

  /// Optional trailing metric/count shown beside the chevron when no active
  /// [trailingBadge] takes precedence.
  final String? trailingText;

  /// Whether to show the trailing navigation chevron (`false` in wide
  /// master-detail left rails to reclaim `28dp` of horizontal text width).
  final bool showChevron;

  /// Optical size of leading icons across top-level navigation and settings rows.
  static const double leadingIconSize = 22;

  /// State-layered ink overlay on top of a selected [primaryContainer] row,
  /// distinguishing pressed (`0.20`), hovered (`0.16`), and focused/default
  /// (`0.12`) states instead of collapsing them into a flat fill.
  static WidgetStateProperty<Color?> selectedOverlayColor(ColorScheme scheme) =>
      WidgetStateProperty.resolveWith((states) {
        final ink = scheme.onPrimaryContainer;
        if (states.contains(WidgetState.pressed)) {
          return ink.withValues(alpha: 0.20);
        }
        if (states.contains(WidgetState.hovered)) {
          return ink.withValues(alpha: 0.16);
        }
        if (states.contains(WidgetState.focused)) {
          return ink.withValues(alpha: 0.12);
        }
        return ink.withValues(alpha: 0.12);
      });

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overlay = selected ? selectedOverlayColor(scheme) : null;
    final pressedColor = overlay?.resolve(const {WidgetState.pressed});
    final trailingBadge = this.trailingBadge;
    final trailingText = this.trailingText;
    final trailingTextWidget = trailingText == null
        ? null
        : Text(
            trailingText,
            style: theme.textTheme.bodyMedium
                ?.copyWith(
                  color: selected
                      ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
                      : scheme.onSurfaceVariant,
                )
                .tabular,
          );
    final Widget? trailing;
    if (trailingBadge != null) {
      trailing = showChevron
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailingTextWidget != null) ...[
                  trailingTextWidget,
                  const SizedBox(width: FuncSpacing.xs),
                ],
                trailingBadge,
                const SizedBox(width: FuncSpacing.xs),
                const Icon(Icons.chevron_right),
              ],
            )
          : trailingTextWidget == null
          ? trailingBadge
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                trailingTextWidget,
                const SizedBox(width: FuncSpacing.xs),
                trailingBadge,
              ],
            );
    } else if (trailingTextWidget != null) {
      trailing = showChevron
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                trailingTextWidget,
                const SizedBox(width: FuncSpacing.xs),
                const Icon(Icons.chevron_right),
              ],
            )
          : trailingTextWidget;
    } else {
      trailing = showChevron ? const Icon(Icons.chevron_right) : null;
    }
    Widget tile = ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer,
      selectedColor: scheme.onPrimaryContainer,
      hoverColor: overlay?.resolve(const {WidgetState.hovered}),
      focusColor: overlay?.resolve(const {WidgetState.focused}),
      leading: icon == null
          ? null
          : Icon(
              selected ? (selectedIcon ?? icon) : icon,
              size: leadingIconSize,
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
      title: Text(settingsRowTitle(context, title, setting)),
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
    );
    if (selected && pressedColor != null) {
      tile = Theme(
        data: theme.copyWith(
          highlightColor: pressedColor,
          splashColor: pressedColor,
        ),
        child: tile,
      );
    }
    return anchorSettingsRow(setting, tile);
  }
}
