import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/entity/illust_entity.dart';

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
  final ValueChanged<IllustEntity> onInspect;
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
