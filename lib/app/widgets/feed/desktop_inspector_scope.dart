import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/settings/app_settings.dart';
import '../../window/desktop_command_bar.dart';
import 'feed_grid.dart';

/// Minimum viewport width required to mount the desktop side inspector cleanly.
const double desktopInspectorMinWidth = 1040;

/// Minimum host content width needed so the feed retains >= 320dp alongside
/// the 440–560dp side inspector panel.
const double desktopInspectorHostMinWidth = 760;

/// Whether the current desktop surface is wide enough and configured to open
/// artworks inside the adjacent gallery inspector.
bool canUseDesktopInspector(
  BuildContext context,
  DesktopDetailMode detailMode,
) =>
    DesktopCommandBarScope.isActiveOf(context) &&
    MediaQuery.widthOf(context) >= desktopInspectorMinWidth &&
    detailMode == DesktopDetailMode.inspector;

/// Metadata captured from the feed card that launched the desktop inspector,
/// preserving exact hero origin and pager navigation when promoted to full stage.
class DesktopInspectorTarget {
  const DesktopInspectorTarget({
    required this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.pagerSource,
  });

  final IllustEntity entity;
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;
  final IllustPagerSource? pagerSource;
}

/// Publishes the desktop inline gallery inspector controller so [IllustCard]
/// paints a crisp selection outline when inspected and routes primary taps into
/// the adjacent inspector panel instead of immediately pushing a modal route.
class DesktopInspectorScope extends InheritedWidget {
  const DesktopInspectorScope({
    super.key,
    required this.selectedId,
    required this.onInspect,
    this.enabled = true,
    required super.child,
  });

  final ValueListenable<int?> selectedId;
  final ValueChanged<DesktopInspectorTarget> onInspect;
  final bool enabled;

  /// Non-subscribing lookup (for gesture callbacks or tests inspecting tree
  /// state). Returns null when the inspector mode is disabled.
  static DesktopInspectorScope? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<DesktopInspectorScope>();
    if (element == null) return null;
    final scope = element.widget as DesktopInspectorScope;
    return scope.enabled ? scope : null;
  }

  /// Subscribing lookup used during widget build so cards rebuild immediately
  /// when desktop detail mode toggles between modal and side inspector.
  static DesktopInspectorScope? watchOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DesktopInspectorScope>();
    if (scope == null || !scope.enabled) return null;
    return scope;
  }

  @override
  bool updateShouldNotify(DesktopInspectorScope oldWidget) =>
      enabled != oldWidget.enabled ||
      !identical(selectedId, oldWidget.selectedId) ||
      onInspect != oldWidget.onInspect;
}
