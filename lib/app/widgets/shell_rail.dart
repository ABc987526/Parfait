import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../layout/form_factor.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import '../window/desktop_command_bar.dart';
import '../window/desktop_title_bar.dart';
import 'fit_label.dart';
import 'func_bottom_nav.dart';

/// The shell's side rail on larger screens, after Shaft's tablet rail
/// (`HomeNavigationRail`): a header, the destinations from the top, a
/// short rule, then shortcuts to the bookmarks and the downloads that open
/// their pages without taking the selection. The selected destination
/// sits on a light fill of the theme colour; the rail casts the bars'
/// shadow over the content beside it instead of a divider. It scrolls when
/// the window is too short for it.
///
/// Collapsed it is [width] wide, each destination an icon over its label;
/// the header is the app's icon, or on a PC ([FormFactor.pc]) the button
/// that opens it. Open ([expanded], PC only) it is [expandedWidth] wide,
/// each entry an icon beside its label, under the button that closes it
/// and the app's name.
///
/// The destinations read as tabs ("Recommended, tab 1 of 5"), as on the
/// bottom bar; the shortcuts are plain buttons outside that group.
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.form,
    required this.expanded,
    required this.onToggle,
    this.onBookmarks,
    this.onDownloads,
    this.onSettings,
    this.onToggleTheme,
    this.isDarkMode,
    this.canToggle,
  });

  final List<FuncBottomNavDestination> destinations;

  /// Null while the page on screen belongs to a destination off the bar.
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final FormFactor form;
  final bool expanded;

  /// Opens or closes the rail; shown on PCs and large touch layouts.
  final VoidCallback onToggle;
  final VoidCallback? onBookmarks;
  final VoidCallback? onDownloads;
  final VoidCallback? onSettings;
  final VoidCallback? onToggleTheme;
  final bool? isDarkMode;
  final bool? canToggle;

  static const double width = 74;
  static const double expandedWidth = 204;

  static const double _headerHeight = 44;
  static const double _itemWidth = 60;
  static const double _itemMinHeight = 52;
  static const double _rowHeight = 42;
  static const double _ruleWidth = 36;
  static const double _iconSize = 20;
  static const double _itemRadius = 10;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final navTheme = NavigationBarTheme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final hairline = BorderSide(color: tokens.brandHairline);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: navTheme.backgroundColor ?? colors.surfaceContainerLow,
        border: BorderDirectional(end: hairline),
      ),
      // The content lays out at the panel's width even while the shell
      // animates the rail's width; clip it at the rail's current edge so the
      // part beyond the rail never paints over the page beside it.
      child: ClipRect(
        child: SafeArea(
          left: !rtl,
          right: rtl,
          minimum:
              DesktopChromeMetrics.maybeOf(context)?.topSafePadding ??
              EdgeInsets.zero,
          // The labels stop growing past the bottom bar's 1.3 ceiling.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            // Anchor rail entries cleanly to the top edge rather than floating
            // halfway down tall desktop monitors.
            child: OverflowBox(
              alignment: AlignmentDirectional.topStart,
              minWidth: expandedWidth,
              maxWidth: expandedWidth,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: expanded
                            ? FuncSpacing.sm + FuncSpacing.xxs
                            : 0,
                        vertical: FuncSpacing.sm,
                      ),
                      // The column and the panel cross-fade while the rail's
                      // width animates; the clip keeps the wider form from
                      // spilling past the still-narrow edge.
                      child: ClipRect(
                        child: AnimatedSwitcher(
                          duration: MotionTokens.resolve(
                            context,
                            MotionTokens.chrome,
                          ),
                          switchInCurve: MotionTokens.chromeCurve,
                          switchOutCurve: MotionTokens.chromeCurve,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: AlignmentDirectional.topStart,
                            children: [
                              for (final child in previous) child,
                              ?current,
                            ],
                          ),
                          child: KeyedSubtree(
                            key: ValueKey(expanded),
                            child: expanded
                                ? _panel(
                                    context,
                                    minHeight:
                                        (constraints.maxHeight -
                                                FuncSpacing.sm * 2)
                                            .clamp(0.0, double.infinity),
                                  )
                                : Align(
                                    alignment: AlignmentDirectional.topStart,
                                    child: SizedBox(
                                      width: width,
                                      child: _column(
                                        context,
                                        minHeight:
                                            (constraints.maxHeight -
                                                    FuncSpacing.sm * 2)
                                                .clamp(0.0, double.infinity),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The label style of an entry, selected or not, over the ambient one so
  /// the app's font carries through.
  TextStyle _labelStyle(BuildContext context, {required bool selected}) =>
      DefaultTextStyle.of(context).style.merge(
        NavigationBarTheme.of(
          context,
        ).labelTextStyle?.resolve({if (selected) WidgetState.selected}),
      );

  Color? _iconColor(BuildContext context, {required bool selected}) =>
      NavigationBarTheme.of(
        context,
      ).iconTheme?.resolve({if (selected) WidgetState.selected})?.color;

  Widget _column(BuildContext context, {required double minHeight}) {
    final l10n = context.l10n;
    // One label size for every entry, shrunk until the widest fits.
    final fit = LabelFit.group(
      labels: [
        for (final d in destinations) d.label,
        l10n.railBookmarks,
        l10n.railDownloads,
      ],
      style: LabelFit.paintedStyle(
        context,
        _labelStyle(context, selected: true),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      slotWidth: _itemWidth - 2 * FuncSpacing.xs,
      locale: Localizations.maybeLocaleOf(context),
    );
    Widget item({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) => _RailEntry(
      selected: selected,
      onTap: onTap,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_itemRadius)),
      ),
      child: SizedBox(
        width: _itemWidth,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _itemMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: FuncSpacing.sm,
              horizontal: FuncSpacing.xs,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: _iconSize,
                  color: _iconColor(context, selected: selected),
                ),
                const SizedBox(height: FuncSpacing.xs),
                FitLabel(
                  label,
                  fit: fit,
                  style: _labelStyle(context, selected: selected),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final size = MediaQuery.sizeOf(context);
    final toggleable =
        canToggle ?? form.canToggleRail(size.width, height: size.height);
    final hideHeader = DesktopCommandBarScope.isActiveOf(context);
    final isDark =
        isDarkMode ?? Theme.of(context).brightness == Brightness.dark;
    final top = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hideHeader)
          const SizedBox(height: FuncSpacing.md)
        else ...[
          SizedBox(
            height: _headerHeight,
            child: Center(
              child: toggleable
                  ? IconButton(
                      onPressed: onToggle,
                      tooltip: l10n.railExpand,
                      icon: const Icon(Icons.menu),
                    )
                  : const _AppIcon(size: FuncSpacing.xxl),
            ),
          ),
          const SizedBox(height: FuncSpacing.xl),
        ],
        _destinations(
          (i, selected) => item(
            icon: destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.sm,
        ),
        if (!hideHeader && (onBookmarks != null || onDownloads != null)) ...[
          Container(
            width: _ruleWidth,
            height: 1,
            margin: const EdgeInsets.only(
              top: FuncSpacing.xs,
              bottom: FuncSpacing.lg + FuncSpacing.xs,
            ),
            color: FuncSemanticTokens.of(context).brandHairline,
          ),
          if (onBookmarks != null)
            item(
              icon: Icons.favorite_border,
              label: l10n.railBookmarks,
              selected: false,
              onTap: onBookmarks!,
            ),
          if (onDownloads != null) ...[
            const SizedBox(height: FuncSpacing.sm),
            item(
              icon: Icons.downloading_outlined,
              label: l10n.railDownloads,
              selected: false,
              onTap: onDownloads!,
            ),
          ],
        ],
      ],
    );
    if (!hideHeader || (onToggleTheme == null && onSettings == null)) {
      return top;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          top,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _ruleWidth,
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
                color: FuncSemanticTokens.of(context).brandHairline,
              ),
              if (onToggleTheme != null)
                IconButton(
                  key: const Key('rail-theme-toggle'),
                  tooltip:
                      '${l10n.themeSettings} · ${isDark ? l10n.dark : l10n.light}',
                  onPressed: onToggleTheme,
                  icon: Icon(
                    isDark
                        ? Icons.dark_mode_outlined
                        : Icons.light_mode_outlined,
                    size: _iconSize,
                  ),
                ),
              if (onSettings != null) ...[
                const SizedBox(height: FuncSpacing.xxs),
                IconButton(
                  key: const Key('rail-settings'),
                  tooltip: l10n.settingsTitle,
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined, size: _iconSize),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context, {required double minHeight}) {
    final l10n = context.l10n;
    final labelSize = Theme.of(context).textTheme.labelLarge?.fontSize;
    Widget row({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) => _RailEntry(
      selected: selected,
      onTap: onTap,
      accentBar: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_itemRadius)),
      ),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: FuncSpacing.md + FuncSpacing.xxs,
            end: FuncSpacing.md,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: _iconSize,
                color: _iconColor(context, selected: selected),
              ),
              const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _labelStyle(
                    context,
                    selected: selected,
                  ).copyWith(fontSize: labelSize),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final size = MediaQuery.sizeOf(context);
    final toggleable =
        canToggle ?? form.canToggleRail(size.width, height: size.height);
    final hideHeader = DesktopCommandBarScope.isActiveOf(context);
    final isDark =
        isDarkMode ?? Theme.of(context).brightness == Brightness.dark;
    final top = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hideHeader)
          const SizedBox(height: FuncSpacing.xs)
        else ...[
          SizedBox(
            height: _headerHeight,
            child: Row(
              children: [
                IconButton(
                  onPressed: onToggle,
                  tooltip: l10n.railCollapse,
                  icon: const Icon(Icons.menu_open),
                ),
                const SizedBox(width: FuncSpacing.xs),
                const _AppIcon(size: FuncSpacing.xl + FuncSpacing.xs),
                const SizedBox(width: FuncSpacing.md),
                Expanded(
                  child: Text(
                    'Parfait',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: FuncSpacing.xl),
        ],
        _destinations(
          (i, selected) => row(
            icon: destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.xs,
          stretch: true,
        ),
        if (!hideHeader && (onBookmarks != null || onDownloads != null)) ...[
          Divider(
            height: FuncSpacing.xl,
            indent: FuncSpacing.lg,
            endIndent: FuncSpacing.lg,
            color: FuncSemanticTokens.of(context).brandHairline,
          ),
          if (onBookmarks != null)
            row(
              icon: Icons.favorite_border,
              label: l10n.railBookmarks,
              selected: false,
              onTap: onBookmarks!,
            ),
          if (onDownloads != null) ...[
            const SizedBox(height: FuncSpacing.xs),
            row(
              icon: Icons.downloading_outlined,
              label: l10n.railDownloads,
              selected: false,
              onTap: onDownloads!,
            ),
          ],
        ],
      ],
    );
    if (!hideHeader ||
        (onToggleTheme == null && onSettings == null && !toggleable)) {
      return top;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(
                height: FuncSpacing.xl,
                indent: FuncSpacing.sm,
                endIndent: FuncSpacing.sm,
                color: FuncSemanticTokens.of(context).brandHairline,
              ),
              if (onToggleTheme != null) ...[
                row(
                  icon: isDark
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  label:
                      '${l10n.themeSettings} · ${isDark ? l10n.dark : l10n.light}',
                  selected: false,
                  onTap: onToggleTheme!,
                ),
                const SizedBox(height: FuncSpacing.xxs),
              ],
              if (onSettings != null) ...[
                row(
                  icon: Icons.settings_outlined,
                  label: l10n.settingsTitle,
                  selected: false,
                  onTap: onSettings!,
                ),
                const SizedBox(height: FuncSpacing.xxs),
              ],
              if (toggleable)
                row(
                  icon: Icons.menu_open,
                  label: l10n.railCollapse,
                  selected: false,
                  onTap: onToggle,
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The destinations as one tab group, each "label, tab i of n" to a
  /// screen reader, as on the bottom bar.
  Widget _destinations(
    Widget Function(int index, bool selected) entry, {
    required double gap,
    bool stretch = false,
  }) {
    return Semantics(
      role: ui.SemanticsRole.tabBar,
      explicitChildNodes: true,
      container: true,
      child: Column(
        crossAxisAlignment: stretch
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < destinations.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            Builder(
              builder: (context) => MergeSemantics(
                child: Semantics(
                  role: ui.SemanticsRole.tab,
                  selected: i == selectedIndex,
                  child: Stack(
                    children: [
                      entry(i, i == selectedIndex),
                      Semantics(
                        label: MaterialLocalizations.of(context).tabLabel(
                          tabIndex: i + 1,
                          tabCount: destinations.length,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One rail entry: a light fill of the theme colour when [selected], the
/// press and hover ink clipped to [shape].
class _RailEntry extends StatelessWidget {
  const _RailEntry({
    required this.selected,
    required this.onTap,
    required this.shape,
    required this.child,
    this.accentBar = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final RoundedRectangleBorder shape;
  final Widget child;
  final bool accentBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final selectedBg = accentBar
        ? (theme.brightness == Brightness.dark
              ? colors.surfaceContainerHigh
              : tokens.surface)
        : tokens.brandTint;
    final effectiveShape = shape.copyWith(
      side: selected
          ? BorderSide(
              color: accentBar ? tokens.brandHairline : tokens.brandTintStroke,
            )
          : BorderSide.none,
    );
    return Semantics(
      button: true,
      child: Material(
        color: selected ? selectedBg : Colors.transparent,
        shape: effectiveShape,
        child: InkWell(
          customBorder: effectiveShape,
          onTap: onTap,
          child: accentBar && selected
              ? Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [
                    child,
                    PositionedDirectional(
                      start: 5,
                      top: 10,
                      bottom: 10,
                      width: 3.5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: FuncShape.pill,
                        ),
                      ),
                    ),
                  ],
                )
              : child,
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/parfait_icon.png',
    width: size,
    height: size,
    excludeFromSemantics: true,
  );
}
