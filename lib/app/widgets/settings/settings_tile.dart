import 'package:material_ui/material_ui.dart';

import '../../theme/category_colors.dart';
import 'settings_anchor.dart';

/// A row that opens another page; its chevron says so. On a sub-page the
/// icon is bare, like the setting rows around it (SET-08).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.selected = false,
    this.trailingBadge,
    this.showChevron = true,
  }) : tone = null;

  /// An entry of a top-level page (the settings index, the Me tab): the
  /// icon sits in a circle of its group's [tone], setting the categories
  /// apart.
  const SettingsTile.topLevel({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.selected = false,
    required CategoryTone this.tone,
    this.trailingBadge,
    this.showChevron = true,
  });

  /// The circle's colors; null on a sub-page, whose icon is bare.
  final CategoryTone? tone;

  /// Optional leading icon. Sub-page entries without a distinctive icon
  /// leave it null instead of picking a filler glyph.
  final IconData? icon;

  /// The title; defaults to the title of [setting].
  final String? title;

  /// The catalog entry this row is the place of (settings search).
  final SettingsEntry? setting;
  final VoidCallback onTap;

  /// Optional summary row (the current value, Android-settings style).
  /// When null the tile renders exactly as before.
  final Widget? subtitle;

  /// Whether this row represents the active master-detail destination.
  final bool selected;

  /// Optional trailing badge (e.g. active task count) shown beside or in place
  /// of the chevron.
  final Widget? trailingBadge;

  /// Whether to show the trailing navigation chevron (`false` in wide
  /// master-detail left rails to reclaim `28dp` of horizontal text width).
  final bool showChevron;

  /// Diameter of the tonal circle behind the icon.
  static const double iconDiameter = 40;

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
    final tone = this.tone;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overlay = selected ? selectedOverlayColor(scheme) : null;
    final pressedColor = overlay?.resolve(const {WidgetState.pressed});
    final trailingBadge = this.trailingBadge;
    final Widget? trailing = switch ((trailingBadge, showChevron)) {
      (final badge?, true) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          badge,
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      (final badge?, false) => badge,
      (null, true) => const Icon(Icons.chevron_right),
      (null, false) => null,
    };
    Widget tile = ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer,
      selectedColor: scheme.onPrimaryContainer,
      hoverColor: overlay?.resolve(const {WidgetState.hovered}),
      focusColor: overlay?.resolve(const {WidgetState.focused}),
      leading: icon == null
          ? null
          : tone == null
          ? Icon(icon)
          : SizedBox.square(
              dimension: iconDiameter,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tone.fill,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tone.ink),
              ),
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
